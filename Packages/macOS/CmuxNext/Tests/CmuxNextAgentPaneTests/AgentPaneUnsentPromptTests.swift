import Foundation
import Testing
import CmuxNextCompat
import CmuxNextDesign
@testable import CmuxNextAgentPane

/// A prompt the person sent that acpmux never acknowledged survives the app's end (a crash, a
/// quit, an update relaunch) and goes again exactly once afterwards, at the relay boundary: the
/// page's frames into ``AgentPaneTransport`` against a stand-in acpmux. A relaunch is a new
/// ``AgentPanePromptJournal`` on the same file and a new transport: nothing of the first run's
/// memory is left, as after a crash. The pane's own storage does not survive a relaunch, so the
/// host keeps the prompt; acpmux runs the resent prompt id at most once (`hub/turns.rs`, its
/// ledger and `logged_prompt`, covered by `a_resend_after_a_restart_is_answered_from_the_log`).
@Suite(.serialized)
@MainActor
struct AgentPaneUnsentPromptTests {
    static let daemon = "/tmp/cmux-unsent-prompt-test/acpmux.sock"

    nonisolated final class Clock: Sendable {
        private let value = Mutex(Date(timeIntervalSince1970: 2_000_000_000))
        var now: Date { value.withLock { $0 } }
        func advance(_ seconds: TimeInterval) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
    }

    struct Pane {
        let server: AcpmuxStandInServer
        let transport: AgentPaneTransport
        let inbox: AgentPaneRelayedAllowTests.PageInbox
        let id: Int
    }

    static func journalURL() -> URL {
        FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("unsent-prompt-\(UUID().uuidString)").appendingPathComponent(AgentPanePromptJournal.fileName)
    }

    /// One app run's pane on `server`: a fresh transport with `journal`, opened and initialized.
    static func pane(_ server: AcpmuxStandInServer, journal: AgentPanePromptJournal) async throws -> Pane {
        let inbox = AgentPaneRelayedAllowTests.PageInbox()
        let transport = AgentPaneTransport()
        transport.promptJournal = journal
        transport.webModes = { _, _, _ in nil }
        transport.deliver = { event, done in inbox.deliver(event.frames); done() }
        transport.sessions.add("s-1")
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil, socketPath: daemon))
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#]) == nil)
        return Pane(server: server, transport: transport, inbox: inbox, id: id)
    }

    static func prompt(id: Int, promptId: String) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"session/prompt","params":{"sessionId":"s-1","prompt":[{"type":"text","text":"Fix the flaky test"}],"_meta":{"acpmux":{"promptId":"\#(promptId)"}}}}"#
    }

    /// The `session/prompt` frames connection `index` of `server` got, parsed.
    nonisolated static func prompts(_ server: AcpmuxStandInServer, peer index: Int) -> [[String: Any]] {
        let peers = server.peers
        guard peers.indices.contains(index) else { return [] }
        return peers[index].frames.compactMap { text in
            guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
                  object["method"] as? String == "session/prompt" else { return nil }
            return object
        }
    }

    nonisolated static func mux(_ frame: [String: Any]) -> [String: Any]? {
        (((frame["params"] as? [String: Any])?["_meta"] as? [String: Any])?["acpmux"]) as? [String: Any]
    }

    /// Waits until the page's later request on `pane` is answered: every frame the host sent on
    /// that connection before it (a resend goes right after `initialize`) reached the daemon.
    static func barrier(_ pane: Pane, id: Int) async {
        #expect(await pane.transport.send(connection: pane.id, frames: [#"{"jsonrpc":"2.0","id":\#(id),"method":"_acpmux/status","params":{}}"#]) == nil)
        _ = await pane.inbox.frame(containing: #""id":\#(id)"#)
    }

    /// The first run sends a prompt; the daemon takes it but the app ends before acpmux's
    /// acknowledgement. The relaunch sends it once, as a resend of the same prompt id, and no
    /// later connection or launch sends it again.
    @Test func aPromptTheDaemonNeverAcknowledgedGoesAgainOnceAfterARelaunch() async throws {
        let url = Self.journalURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let first = AcpmuxStandInServer()
        try await first.start()
        defer { first.stop() }
        // The harness is slow: no reply and no `_acpmux/prompt_accepted` before the app ends.
        first.hold("session/prompt")
        let run1 = try await Self.pane(first, journal: AgentPanePromptJournal(url: url))
        run1.transport.gestures.record()
        #expect(await run1.transport.send(connection: run1.id, frames: [Self.prompt(id: 1, promptId: "p-1")]) == nil)
        #expect(await first.wait { _ in Self.prompts(first, peer: 0).count == 1 })
        // The app crashes here: nothing of this run runs again (the first daemon keeps the
        // connection, as a daemon whose app vanished does until it notices).

        // The relaunch: a new journal on the same file, a new pane, the daemon on the same socket path.
        let daemon = AcpmuxStandInServer()
        try await daemon.start()
        defer { daemon.stop() }
        let journal = AgentPanePromptJournal(url: url)
        let run2 = try await Self.pane(daemon, journal: journal)
        await Self.barrier(run2, id: 2)
        let resent = Self.prompts(daemon, peer: 0)
        #expect(resent.count == 1, "the unacknowledged prompt was not sent again after the relaunch")
        guard let frame = resent.first else { return }
        #expect(Self.mux(frame)?["promptId"] as? String == "p-1")
        #expect(Self.mux(frame)?["resend"] as? Bool == true, "a prompt sent again must say so, so acpmux runs it at most once")
        #expect(((frame["params"] as? [String: Any])?["prompt"] as? [[String: Any]])?.first?["text"] as? String == "Fix the flaky test")

        // acpmux answered it: another pane of this run and the next launch send nothing.
        await journal.settle()
        #expect(journal.entries().isEmpty)
        let other = try await Self.pane(daemon, journal: journal)
        await Self.barrier(other, id: 3)
        #expect(Self.prompts(daemon, peer: 1).isEmpty)
        let run3 = try await Self.pane(daemon, journal: AgentPanePromptJournal(url: url))
        await Self.barrier(run3, id: 4)
        #expect(Self.prompts(daemon, peer: 2).isEmpty, "a prompt acpmux answered went again at the next launch")
    }

    /// An app relaunch while the daemon is still holding a compose keeps the prompt in the host
    /// journal. The replacement pane receives it once, without making the person retype it.
    @Test func anAppRelaunchMidComposeKeepsThePromptAndRecovers() async throws {
        let url = Self.journalURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let first = AcpmuxStandInServer()
        try await first.start()
        defer { first.stop() }
        first.hold("session/prompt")
        let run1 = try await Self.pane(first, journal: AgentPanePromptJournal(url: url))
        run1.transport.gestures.record()
        #expect(await run1.transport.send(connection: run1.id, frames: [Self.prompt(id: 1, promptId: "restart-1")]) == nil)
        #expect(await first.wait { _ in Self.prompts(first, peer: 0).count == 1 })

        let replacement = AcpmuxStandInServer()
        try await replacement.start()
        defer { replacement.stop() }
        replacement.hold("session/prompt")
        let run2 = try await Self.pane(replacement, journal: AgentPanePromptJournal(url: url))
        await Self.barrier(run2, id: 2)
        let resent = Self.prompts(replacement, peer: 0)
        #expect(resent.count == 1)
        #expect(Self.mux(resent[0])?["promptId"] as? String == "restart-1")
        #expect(Self.mux(resent[0])?["resend"] as? Bool == true)
        #expect(AgentPanePromptJournal(url: url).entries().count == 1, "the prompt remains until the replacement daemon acknowledges it")
    }

    /// The daemon closes the connection before it acknowledged a prompt (an acpmux restart, a reset
    /// socket). With Debug Settings agentPane.debug.lostPromptReplay on, the pane's next connection
    /// sends it again, once, as a resend of the same prompt id ("The agent connection was
    /// interrupted", 2026-10-20). Off (the default), it never goes again: the page says "Not sent"
    /// with Retry, so the prompt runs at most once whichever way.
    @Test(arguments: [true, false])
    func aPromptTheDaemonDroppedWithItsConnectionGoesAgainOnTheNextOne(replay: Bool) async throws {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(AgentPaneTunables.all)
        TunableStore.shared.set(AgentPaneTunables.lostPromptReplay.key, .bool(replay))
        defer { TunableStore.shared.set(AgentPaneTunables.lostPromptReplay.key, nil) }
        let url = Self.journalURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let daemon = AcpmuxStandInServer()
        try await daemon.start()
        defer { daemon.stop() }
        daemon.hold("session/prompt")
        let pane = try await Self.pane(daemon, journal: AgentPanePromptJournal(url: url))
        let received = Mutex<[String]>([])
        pane.transport.deliver = { event, done in
            received.withLock { $0 += event.frames + (event.closed == nil ? [] : ["<closed>"]) }
            done()
        }
        pane.transport.gestures.record()
        #expect(await pane.transport.send(connection: pane.id, frames: [Self.prompt(id: 1, promptId: "p-5")]) == nil)
        #expect(await daemon.wait { _ in Self.prompts(daemon, peer: 0).count == 1 })
        daemon.pushThenClose([], to: 0)
        try #require(await daemon.wait { _ in received.withLock { $0.contains("<closed>") } }, "the daemon's close never reached the page")

        let again = try await pane.transport.open(
            AcpmuxConnection(url: daemon.url, dashboardToken: "t", localAppToken: nil, socketPath: Self.daemon))
        #expect(await pane.transport.send(connection: again, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#]) == nil)
        // Every frame the host sent on the new connection before this request reached the daemon.
        #expect(await pane.transport.send(connection: again, frames: [#"{"jsonrpc":"2.0","id":2,"method":"_acpmux/status","params":{}}"#]) == nil)
        try #require(await daemon.wait { _ in received.withLock { $0.contains { $0.contains(#""id":2"#) } } }, "the new connection never answered")
        let resent = Self.prompts(daemon, peer: 1)
        guard replay else {
            #expect(resent.isEmpty, "with the replay off, the page owns the dropped prompt (Retry): it must not go again")
            return
        }
        #expect(resent.count == 1, "the prompt the daemon dropped with its connection was not sent again")
        guard let frame = resent.first else { return }
        #expect(Self.mux(frame)?["promptId"] as? String == "p-5")
        #expect(Self.mux(frame)?["resend"] as? Bool == true, "a prompt sent again must say so, so acpmux runs it at most once")
    }

    /// A prompt acpmux acknowledged (`_acpmux/prompt_accepted`) is in its session log: the
    /// relaunch never sends it, even when its turn was still running as the app ended.
    @Test func anAcknowledgedPromptIsNotSentAgain() async throws {
        let url = Self.journalURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = AcpmuxStandInServer()
        try await first.start()
        defer { first.stop() }
        first.hold("session/prompt")
        let journal = AgentPanePromptJournal(url: url)
        let run1 = try await Self.pane(first, journal: journal)
        run1.transport.gestures.record()
        #expect(await run1.transport.send(connection: run1.id, frames: [Self.prompt(id: 1, promptId: "p-2")]) == nil)
        #expect(await first.wait { _ in Self.prompts(first, peer: 0).count == 1 })
        first.push(#"{"jsonrpc":"2.0","method":"_acpmux/prompt_accepted","params":{"sessionId":"s-1","promptId":"p-2","turnId":"t-1","queued":false}}"#, to: 0)
        _ = await run1.inbox.frame(containing: "prompt_accepted")
        await journal.settle()

        let daemon = AcpmuxStandInServer()
        try await daemon.start()
        defer { daemon.stop() }
        let run2 = try await Self.pane(daemon, journal: AgentPanePromptJournal(url: url))
        await Self.barrier(run2, id: 2)
        #expect(Self.prompts(daemon, peer: 0).isEmpty)
    }

    /// A prompt left for longer than a day is dropped at the next launch, not sent.
    @Test func aPromptOlderThanADayIsDroppedNotSent() async throws {
        let url = Self.journalURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let clock = Clock()
        let first = AcpmuxStandInServer()
        try await first.start()
        defer { first.stop() }
        first.hold("session/prompt")
        let run1 = try await Self.pane(first, journal: AgentPanePromptJournal(url: url, now: { clock.now }))
        run1.transport.gestures.record()
        #expect(await run1.transport.send(connection: run1.id, frames: [Self.prompt(id: 1, promptId: "p-3")]) == nil)
        #expect(await first.wait { _ in Self.prompts(first, peer: 0).count == 1 })

        clock.advance(AgentPanePromptJournal.maximumAge + 60)
        let daemon = AcpmuxStandInServer()
        try await daemon.start()
        defer { daemon.stop() }
        let journal = AgentPanePromptJournal(url: url, now: { clock.now })
        let run2 = try await Self.pane(daemon, journal: journal)
        await Self.barrier(run2, id: 2)
        #expect(Self.prompts(daemon, peer: 0).isEmpty)
        #expect(journal.entries().isEmpty)
    }

    /// The pane's Retry sends a prompt again under its prompt id, and the page may not mark it a
    /// resend: the host does, for an id it sent this daemon before, so acpmux also looks for a
    /// first copy in the chat's log (which a daemon restart keeps). A first send is not marked.
    @Test func aRetriedPromptIdGoesAsAResend() async throws {
        let url = Self.journalURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let daemon = AcpmuxStandInServer()
        try await daemon.start()
        defer { daemon.stop() }
        // No answer to the first send: the page gives up on it and offers Retry.
        daemon.hold("session/prompt")
        let pane = try await Self.pane(daemon, journal: AgentPanePromptJournal(url: url))
        pane.transport.gestures.record()
        #expect(await pane.transport.send(connection: pane.id, frames: [Self.prompt(id: 1, promptId: "p-5")]) == nil)
        pane.transport.gestures.record()
        #expect(await pane.transport.send(connection: pane.id, frames: [Self.prompt(id: 2, promptId: "p-5")]) == nil)
        #expect(await daemon.wait { _ in Self.prompts(daemon, peer: 0).count == 2 })
        let sent = Self.prompts(daemon, peer: 0)
        try #require(sent.count == 2)
        #expect(Self.mux(sent[0])?["resend"] == nil, "a first send is not a resend")
        #expect(Self.mux(sent[1])?["resend"] as? Bool == true, "a Retry must say so, so acpmux runs the prompt id at most once")
    }

    /// A prompt whose record the host could not write (an unwritable folder, a full disk) does not
    /// go: a crash before acpmux's acknowledgement would lose it for good. The page is told it was
    /// not sent, so it offers Retry, and the Retry goes once the journal can be written.
    @Test func aPromptWhoseRecordIsNotWrittenIsNotSent() async throws {
        let url = Self.journalURL()
        let folder = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        // A file where the journal's folder goes: every write of the journal fails.
        try Data().write(to: folder)
        let daemon = AcpmuxStandInServer()
        try await daemon.start()
        defer { daemon.stop() }
        let journal = AgentPanePromptJournal(url: url)
        let pane = try await Self.pane(daemon, journal: journal)
        pane.transport.gestures.record()
        let result = await pane.transport.send(connection: pane.id, frames: [Self.prompt(id: 1, promptId: "p-6")])
        try #require(result?.rawValue == "transport.prompt_not_kept", "a prompt that is not on disk went without its crash protection")
        await Self.barrier(pane, id: 2)
        #expect(Self.prompts(daemon, peer: 0).isEmpty, "the daemon got a prompt the host could not keep")
        #expect(await pane.inbox.frame(containing: #""id":1"#).contains("transport.prompt_not_kept"))
        #expect(journal.entries().isEmpty)

        try FileManager.default.removeItem(at: folder)
        pane.transport.gestures.record()
        #expect(await pane.transport.send(connection: pane.id, frames: [Self.prompt(id: 3, promptId: "p-6")]) == nil)
        #expect(await daemon.wait { _ in Self.prompts(daemon, peer: 0).count == 1 }, "the Retry did not go once the journal could be written")
        let sent = Self.prompts(daemon, peer: 0)
        #expect(sent.first.flatMap { Self.mux($0)?["resend"] } == nil, "a prompt that never went is not a resend")
    }

    /// The connection ends (the host closed it) while a prompt's record fails to write: the prompt
    /// was refused, so it is not left over for the next connection to send after all.
    @Test func aPromptRefusedWhileItsConnectionEndsIsNotSentLater() async throws {
        let url = Self.journalURL()
        let folder = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: folder)
        let daemon = AcpmuxStandInServer()
        try await daemon.start()
        defer { daemon.stop() }
        let journal = AgentPanePromptJournal(url: url)
        let pane = try await Self.pane(daemon, journal: journal)
        let owner = try #require(pane.transport.promptRelay?.owner)
        journal.whileRecordWrites.withLock { $0 = { journal.connectionEnded(owner: owner, byDaemon: false) } }
        pane.transport.gestures.record()
        let result = await pane.transport.send(connection: pane.id, frames: [Self.prompt(id: 1, promptId: "p-10")])
        try #require(result?.rawValue == "transport.prompt_not_kept")
        journal.whileRecordWrites.withLock { $0 = nil }
        #expect(journal.entries().isEmpty, "the refused prompt was left over: \(journal.entries().map(\.promptId))")

        let next = try await Self.pane(daemon, journal: journal)
        await Self.barrier(next, id: 2)
        #expect(Self.prompts(daemon, peer: 1).isEmpty, "the next connection sent a prompt that was refused")
    }

    /// Another change while a record writes (a daemon's close hands its page's prompt back): the
    /// record is kept, and the file holds the journal as it is after both, never a prompt that
    /// change took out.
    @Test func aChangeWhileARecordWritesIsOnDiskWithIt() async throws {
        let url = Self.journalURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = AgentPanePromptJournal(url: url)
        let entry = { (id: String) in
            AgentPanePromptJournal.Entry(daemon: Self.daemon, sessionId: "s-1", promptId: id, params: "{}", at: journal.now())
        }
        let other = UUID()
        #expect(try journal.record(entry("p-b"), owner: other))
        journal.whileRecordWrites.withLock { $0 = { journal.connectionEnded(owner: other, byDaemon: true) } }
        let kept = try journal.record(entry("p-a"), owner: UUID())
        journal.whileRecordWrites.withLock { $0 = nil }
        await journal.settle()
        #expect(kept)
        #expect(journal.entries().map(\.promptId) == ["p-a"])
        #expect(AgentPanePromptJournal(url: url).entries().map(\.promptId) == ["p-a"],
                "the file kept a prompt the daemon's close took out")
    }

    /// A change while a record writes, whose own write waits behind the record's, and the record's
    /// second write (of the journal as it is after both) fails: the change still reaches the disk
    /// on the next write, never left out as older than the record.
    @Test func aChangeWhileARecordWritesReachesTheDiskWhenTheSecondWriteFails() async throws {
        let url = Self.journalURL()
        let folder = url.deletingLastPathComponent()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        let journal = AgentPanePromptJournal(url: url)
        let entry = { (id: String) in
            AgentPanePromptJournal.Entry(daemon: Self.daemon, sessionId: "s-1", promptId: id, params: "{}", at: journal.now())
        }
        let other = UUID()
        #expect(try journal.record(entry("p-b"), owner: other))
        journal.whileRecordWrites.withLock { $0 = { journal.connectionEnded(owner: other, byDaemon: true) } }
        journal.afterRecordWrite.withLock {
            $0 = { try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path) }
        }
        #expect(try journal.record(entry("p-a"), owner: UUID()), "the record is on disk; a later write's failure is not its own")
        journal.whileRecordWrites.withLock { $0 = nil }
        journal.afterRecordWrite.withLock { $0 = nil }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        await journal.settle()
        #expect(AgentPanePromptJournal(url: url).entries().map(\.promptId) == ["p-a"],
                "the daemon's close never reached the disk: its prompt would be sent again after a relaunch")
    }

    /// A record over an unreadable journal that cannot be set aside yet (#28204) is refused like any
    /// record that did not reach the disk: the only copy of the earlier prompts is never written over,
    /// and the new prompt does not go.
    @Test func aRecordOverAnUnreadableJournalIsRefusedAndNeverOverwritesIt() throws {
        let url = Self.journalURL()
        let folder = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let corrupt = Data(#"{"entries": [{"promptId": "half a pro"#.utf8)
        try corrupt.write(to: url)
        let journal = AgentPanePromptJournal(url: url, now: { Date(timeIntervalSince1970: 1_000) })
        let aside = url.deletingPathExtension().appendingPathExtension("unreadable-1000")
            .appendingPathExtension(url.pathExtension)
        // Something already at the set-aside name: the move fails.
        try FileManager.default.createDirectory(at: aside.appending(path: "blocker"), withIntermediateDirectories: true)
        let entry = AgentPanePromptJournal.Entry(daemon: Self.daemon, sessionId: "s-1", promptId: "p-11", params: "{}", at: journal.now())
        #expect(throws: AgentPanePromptJournal.NotWritten.self, "a record wrote over the unreadable journal") {
            try journal.record(entry, owner: UUID())
        }
        #expect(try Data(contentsOf: url) == corrupt)
        #expect(journal.entries().isEmpty, "the refused prompt is kept in memory")
    }

    /// The pane's Retry of a prompt the daemon got but never acknowledged, while the journal cannot
    /// be written: the Retry does not go, and the first send's record stays, so a crash after the
    /// disk recovers still sends that prompt again.
    @Test func aRetryWhoseRecordIsNotWrittenKeepsTheEarlierRecord() async throws {
        let url = Self.journalURL()
        let folder = url.deletingLastPathComponent()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        let daemon = AcpmuxStandInServer()
        try await daemon.start()
        defer { daemon.stop() }
        daemon.hold("session/prompt")
        let journal = AgentPanePromptJournal(url: url)
        let pane = try await Self.pane(daemon, journal: journal)
        pane.transport.gestures.record()
        #expect(await pane.transport.send(connection: pane.id, frames: [Self.prompt(id: 1, promptId: "p-7")]) == nil)
        pane.transport.gestures.record()
        #expect(await pane.transport.send(connection: pane.id, frames: [Self.prompt(id: 5, promptId: "p-9")]) == nil)
        #expect(await daemon.wait { _ in Self.prompts(daemon, peer: 0).count == 2 })

        // The folder can no longer be written; the Retry is refused and does not go.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        pane.transport.gestures.record()
        let retry = await pane.transport.send(connection: pane.id, frames: [Self.prompt(id: 2, promptId: "p-7")])
        try #require(retry?.rawValue == "transport.prompt_not_kept", "a Retry that is not on disk went")
        await Self.barrier(pane, id: 3)
        #expect(Self.prompts(daemon, peer: 0).count == 2)

        // The disk recovers and another prompt is written: the first send's record is still there.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        pane.transport.gestures.record()
        #expect(await pane.transport.send(connection: pane.id, frames: [Self.prompt(id: 4, promptId: "p-8")]) == nil)
        #expect(await daemon.wait { _ in Self.prompts(daemon, peer: 0).count == 3 })
        // In its place, too: the oldest record is still the first the journal's limit drops.
        let kept = AgentPanePromptJournal(url: url).entries().map(\.promptId)
        #expect(kept == ["p-7", "p-9", "p-8"], "the Retry's failed write lost or moved the first send's record: \(kept)")
    }

    /// The page cannot send `resend` itself: only the host sends a prompt again, and only one it
    /// recorded from a frame every page rule let through.
    @Test func thePageCannotMarkAPromptAsAResend() async throws {
        let url = Self.journalURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let daemon = AcpmuxStandInServer()
        try await daemon.start()
        defer { daemon.stop() }
        let pane = try await Self.pane(daemon, journal: AgentPanePromptJournal(url: url))
        pane.transport.gestures.record()
        let frame = #"{"jsonrpc":"2.0","id":1,"method":"session/prompt","params":{"sessionId":"s-1","prompt":[{"type":"text","text":"x"}],"_meta":{"acpmux":{"promptId":"p-4","resend":true}}}}"#
        #expect(await pane.transport.send(connection: pane.id, frames: [frame]) != nil)
        await Self.barrier(pane, id: 2)
        #expect(Self.prompts(daemon, peer: 0).isEmpty)
    }
}
