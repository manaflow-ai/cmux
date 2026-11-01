import AppKit
import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextSettings
import CryptoKit
import Foundation
import Testing

/// Bring Back Local (cmuxterm-hq#1874 slice 4) at the app boundary: a chat moved to a Cloud machine
/// with `cmux cloud move` comes back with `cmux cloud bring-back`, both sent as the CLI sends them
/// to the app's real action registry. This Mac and the machine are two real cmux-tui daemons, as
/// in ``CloudMoveTests``; `cmux link sync push|pull` and `cmux link agent move` are a stand-in
/// `cmux` that records its arguments and answers as the case asks. The Rust suites cover those
/// CLIs against daemons (link_sync.rs, bring_back_journey.rs).
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct CloudBringBackTests {
    /// The chat comes back: the machine's folder is merged into the chat's folder here, the chat
    /// moves from the machine's tab to this Mac in that folder, and opens in a local tab bound to
    /// its session on this Mac; then the machine's tab closes.
    @Test func aCLIBringBackEndsWithTheChatInALocalTabAndTheMachineTabClosed() async throws {
        try await Self.withRoundTrip("back") { trip in
            if let error = await trip.bringBack() { Issue.record("cmux cloud bring-back: \(error.code) \(error.message)") }
            try await trip.waitUntil { trip.localChat() != nil && trip.machineChat() == nil }
            let calls = trip.calls()
            #expect(calls.count == 4, "\(calls)")
            #expect(calls.dropFirst(2).first == ["link", "sync", "pull", "--socket", trip.vmSocket, trip.project.path, trip.synced])
            // A running turn moves too, with what it wrote on the machine since the pull.
            #expect(calls.dropFirst(3).first == ["link", "agent", "move", "--from-socket", trip.vmSocket, "--surface", String(trip.machineSurface),
                                                 "--to-socket", trip.macSocket, "--cwd", trip.project.path, "--interrupt",
                                                 "--sync", "pull", "--sync-socket", trip.vmSocket, "--sync-local", trip.project.path,
                                                 "--sync-remote", trip.synced])
            let local = try #require(trip.localChat(), "no chat tab on this Mac")
            #expect(local.agentSession?.session == "chat-live")
            #expect(local.agentSession?.host == trip.services.agentTabs.localHost)
            #expect(trip.machineChat() == nil, "the machine's tab is still open")
            #expect(trip.services.cloud.bringBackRetries[trip.machineKey] == nil)
            // The chat's grants on the machine end with it (cmuxterm-hq#1874 slice 6).
            let revoke = ["link", "access", "revoke", "--machine", "vm-move", "--session", "chat-on-vm", "--socket", trip.vmSocket, "--all"]
            try await trip.waitUntil { trip.accessCalls().contains(revoke) }
            #expect(trip.accessCalls().contains(revoke), "the bring back left the chat's grants: \(trip.accessCalls())")
        }
    }

    /// A revoke that fails after a bring back (the machine didn't answer) never fails the bring back
    /// and is tried again, until it answers ok.
    @Test func aRevokeThatFailsIsTriedAgainUntilItIsDone() async throws {
        try await Self.withRoundTrip("revokeOnce") { trip in
            if let error = await trip.bringBack() { Issue.record("cmux cloud bring-back: \(error.code) \(error.message)") }
            try await trip.waitUntil { trip.localChat() != nil && trip.machineChat() == nil }
            let revoke = ["link", "access", "revoke", "--machine", "vm-move", "--session", "chat-on-vm", "--socket", trip.vmSocket, "--all"]
            @MainActor func revokes() -> Int { trip.accessCalls().filter { $0 == revoke }.count }
            try await trip.waitUntil { revokes() >= 2 }
            #expect(revokes() == 2, "the failed revoke was not tried again once, or not stopped after it was done: \(trip.accessCalls())")
            // Done: no more tries.
            try? await Task.sleep(for: .seconds(8))
            #expect(revokes() == 2, "\(trip.accessCalls())")
        }
    }

    /// A moved chat's agent asks for a file of this Mac (cmuxterm-hq#1874 slice 6): the app's triage
    /// lists it, and the chat's tab on the machine shows a card with Allow once, Always and Deny.
    /// A click without a real gesture in the pane answers nothing; the person's Always answers with
    /// exactly what the card showed, for the chat's machine and session, and the card goes.
    @Test func aFileAskFromAMovedChatShowsACardAndOnlyThePersonsClickAnswersIt() async throws {
        try await Self.withRoundTrip("access") { trip in
            let triage = ["link", "access", "triage", "--socket", trip.vmSocket, "--machine", "vm-move", "--session", "chat-on-vm"]
            let card = try #require(await trip.toolCards()?.first, "no card in the moved chat; calls: \(trip.accessCalls())")
            #expect(trip.accessCalls().contains(triage), "\(trip.accessCalls())")
            #expect(CloudMoveTests.actionIDs(card) == ["allow", "always", "deny"])
            #expect(CloudMoveTests.text(card, "text")?.contains(trip.project.path + "/plan.md") == true, "\(card)")
            let id = try #require(CloudMoveTests.text(card, "id"))
            @MainActor func answers() -> [[String]] { trip.accessCalls().filter { $0.prefix(3) == ["link", "access", "answer"] } }
            #expect(await trip.answer(id, "always", gesture: false)["ok"] as? Bool != true)
            #expect(answers().isEmpty, "a click without a gesture answered: \(answers())")
            #expect(await trip.answer(id, "always", gesture: true)["ok"] as? Bool == true)
            try await trip.waitUntil { !answers().isEmpty }
            let root = try #require(trip.services.cloud.move.workRoots.first)
            #expect(answers() == [["link", "access", "answer", "--socket", trip.vmSocket, "--machine", "vm-move", "--session", "chat-on-vm",
                                   "--request", "0123456789abcdef0123456789abcdef", "--remote-root", root,
                                   "--always", trip.project.path + "/plan.md", "--target", trip.project.path + "/plan.md",
                                   "--folder", trip.project.path]])
            #expect(await trip.toolCards(waiting: false)?.isEmpty == true, "the card stayed after Always")
        }
    }

    /// A moved chat's agent asks for a secret by name (cmuxterm-hq#1874 slice 6): the chat's tab on
    /// the machine shows a card with a password field, Share once and Deny. Share once needs both
    /// a real gesture in the pane and a typed value; the value goes to `link access answer
    /// --share-secret NAME` on stdin only, never in its arguments, and no file this test's world
    /// writes (both daemons' state and logs, the CLI's log) ever holds it. A fake secret only.
    @Test func aSecretAskTakesWhatThePersonTypesOnStdinOnlyAndNoFileHoldsIt() async throws {
        try await Self.withRoundTrip("secret") { trip in
            let card = try #require(await trip.toolCards()?.first, "no card in the moved chat; calls: \(trip.accessCalls())")
            #expect(CloudMoveTests.actionIDs(card) == ["share", "deny"])
            #expect(CloudMoveTests.text(card, "text")?.contains("GITHUB_TOKEN") == true, "\(card)")
            guard case .object(let input)? = card["input"] else {
                Issue.record("the card has no field: \(card)")
                return
            }
            #expect(input["secure"] == .bool(true), "\(input)")
            let id = try #require(CloudMoveTests.text(card, "id"))
            let secret = "fake-secret-" + UUID().uuidString
            @MainActor func answers() -> [[String]] { trip.accessCalls().filter { $0.prefix(3) == ["link", "access", "answer"] } }
            #expect(await trip.answer(id, "share", gesture: false, value: secret)["ok"] as? Bool != true)
            #expect(await trip.answer(id, "share", gesture: true)["ok"] as? Bool != true, "Share once went without a value")
            #expect(await trip.answer(id, "deny", gesture: true, value: secret)["ok"] as? Bool != true, "Deny took a value")
            // Past 16 KiB a secret is refused here: the CLI's stdin is written whole before it starts.
            #expect(await trip.answer(id, "share", gesture: true, value: String(repeating: "x", count: 16 * 1024 + 1))["ok"] as? Bool != true)
            #expect(answers().isEmpty, "a click without a gesture or a value answered: \(answers())")
            #expect(await trip.toolCards(waiting: false)?.first.flatMap { CloudMoveTests.text($0, "id") } == id, "a refused click took the card")
            #expect(await trip.answer(id, "share", gesture: true, value: secret)["ok"] as? Bool == true)
            try await trip.waitUntil { !answers().isEmpty }
            #expect(answers() == [["link", "access", "answer", "--socket", trip.vmSocket, "--machine", "vm-move", "--session", "chat-on-vm",
                                   "--request", "fedcba9876543210fedcba9876543210", "--share-secret", "GITHUB_TOKEN"]])
            let digest = SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined()
            // The CLI's call is logged before it reads stdin: wait for its digest, which appears only once it did.
            let digestFile = trip.root.appendingPathComponent("secret-digest")
            try await trip.waitUntil { FileManager.default.fileExists(atPath: digestFile.path) }
            let received = try? String(contentsOf: digestFile, encoding: .utf8)
            #expect(received?.trimmingCharacters(in: .whitespacesAndNewlines) == digest, "the CLI's stdin was not the typed value")
            #expect(await trip.toolCards(waiting: false)?.isEmpty == true, "the card stayed after Share once")
            #expect(trip.filesHolding(secret).isEmpty, "the secret was written to \(trip.filesHolding(secret))")
        }
    }

    /// A file the person drops or pastes into a chat moved to a Cloud machine, which the composer
    /// can't attach (cmuxterm-hq#1874 slice 6): the page sends its bytes as `chat.upload`, and only
    /// with a real gesture in the pane. The app writes them under this Mac's temporary
    /// `cmux-pastes` folder, runs `cmux link access upload` for the chat's machine and work root,
    /// deletes its copy, and answers the file's path on the machine. A dot file or a name with a
    /// folder in it never reaches the CLI. Fake bytes only.
    @Test func aFileDroppedInAMovedChatGoesToItsMachineFromThisMacsPastesFolderOnly() async throws {
        try await Self.withRoundTrip("upload") { trip in
            let bytes = "fake-upload-" + UUID().uuidString
            let data = Data(bytes.utf8).base64EncodedString()
            let file: [String: Any] = ["name": "diagram.sketch", "data": data]
            @MainActor func uploads() -> [[String]] { trip.accessCalls().filter { $0.prefix(3) == ["link", "access", "upload"] } }
            #expect(await trip.upload([file], gesture: false)["ok"] as? Bool != true, "an upload went without a gesture")
            #expect(await trip.upload([["name": ".env", "data": data]], gesture: true)["ok"] as? Bool != true, "a dot file went")
            #expect(await trip.upload([["name": "../diagram.sketch", "data": data]], gesture: true)["ok"] as? Bool != true, "a path went")
            #expect(uploads().isEmpty, "a refused upload ran the CLI: \(uploads())")
            let reply = await trip.upload([file], gesture: true)
            #expect(reply["ok"] as? Bool == true, "\(reply)")
            let root = try #require(trip.services.cloud.move.workRoots.first)
            let call = try #require(uploads().first, "no upload ran")
            #expect(Array(call.prefix(7)) == ["link", "access", "upload", "--socket", trip.vmSocket, "--remote-root", root], "\(call)")
            // Each file goes under an upload id of the app's own, so a failed or cancelled one is removed.
            #expect(call.count == 10 && call[7] == "--upload-id", "\(call)")
            #expect(call.count == 10 && call[8].utf8.count == 32 && call[8].utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }, "\(call)")
            let sent = try #require(call.last)
            let temporary = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
            let pastes = URL(fileURLWithPath: temporary).appendingPathComponent("cmux-pastes").resolvingSymlinksInPath().path
            #expect(URL(fileURLWithPath: sent).resolvingSymlinksInPath().path.hasPrefix(pastes + "/"), "not from cmux-pastes: \(sent)")
            #expect(URL(fileURLWithPath: sent).lastPathComponent == "diagram.sketch")
            #expect(!FileManager.default.fileExists(atPath: sent), "the pasted copy stayed on this Mac")
            let digest = SHA256.hash(data: Data(bytes.utf8)).map { String(format: "%02x", $0) }.joined()
            let received = try? String(contentsOf: trip.root.appendingPathComponent("upload-digest"), encoding: .utf8)
            #expect(received?.trimmingCharacters(in: .whitespacesAndNewlines) == digest, "the CLI did not get the dropped bytes")
            let listed = ((reply["value"] as? [String: Any])?["uploads"] as? [[String: Any]])?.first
            #expect(listed?["name"] as? String == "diagram.sketch")
            #expect(listed?["path"] as? String == root + "/local/uploads/0123456789abcdef0123456789abcdef/diagram.sketch", "\(reply)")
        }
    }

    /// A conflict stops before the chat moves: the machine's tab stays, the conflicting path is
    /// in the message, and Retry runs the bring back again on the same machine.
    @Test func aSyncConflictKeepsTheMachineTabAndShowsTheConflict() async throws {
        try await Self.withRoundTrip("conflict") { trip in
            let error = try #require(await trip.bringBack(), "the bring back did not report the conflict")
            #expect(error.message.contains("notes.txt"), "the conflict is not shown: \(error.message)")
            #expect(trip.calls().count == 3, "the chat moved after a conflict: \(trip.calls())")
            #expect(trip.machineChat() != nil, "the machine's tab closed though the chat did not move")
            #expect(trip.localChat() == nil)
            #expect(trip.services.cloud.bringBackRetries[trip.machineKey] == .move(machineID: "vm-move"))
        }
    }

    /// A machine whose cmux-tui is too old for the bring back (cx-rppd.13) is named as one in plain
    /// words, not with the CLI's error, and nothing moves: the machine's tab stays and the toast
    /// offers "Update Machine" on that machine.
    @Test func anOutdatedMachineIsNamedAndTheChatStaysOnIt() async throws {
        try await Self.withRoundTrip("outdated") { trip in
            let error = try #require(await trip.bringBack(), "the bring back did not report the older machine")
            #expect(error.message == CloudBringBackStrings.outdatedMachine("Move VM"), "\(error.message)")
            #expect(trip.calls().count == 3, "the chat moved from an older machine: \(trip.calls())")
            #expect(trip.machineChat() != nil, "the machine's tab closed though the chat did not move")
            #expect(trip.localChat() == nil)
            #expect(trip.services.cloud.bringBackRetries[trip.machineKey] == .update(machineID: "vm-move"))
        }
    }

    /// "Update Machine" (cx-rppd.13) on a machine too old for the bring back updates it through
    /// `cmux link machine update` with only its socket, then brings the chat back.
    @Test func updateMachineUpdatesAnOutdatedMachineThenBringsTheChatBack() async throws {
        try await Self.withRoundTrip("updates") { trip in
            #expect(await trip.bringBack() != nil, "the bring back did not report the older machine")
            #expect(trip.services.cloud.bringBackRetries[trip.machineKey] == .update(machineID: "vm-move"))
            let before = trip.calls().count
            let update = ActionInvocation(target: ActionTargetRef(kind: .tab, id: trip.machineKey),
                                          arguments: [CloudMachineUpdate.argument: .bool(true)], origin: .user)
            #expect(trip.services.registry.perform(CloudBringBack.action, invocation: update))
            try await trip.waitUntil { trip.localChat() != nil && trip.machineChat() == nil }
            let calls = Array(trip.calls().dropFirst(before))
            #expect(calls.first == ["link", "machine", "update", "--socket", trip.vmSocket], "\(calls)")
            #expect(calls.dropFirst().map { Array($0.prefix(3)) } == [["link", "sync", "pull"], ["link", "agent", "move"]], "\(calls)")
            #expect(trip.localChat()?.agentSession?.session == "chat-live")
        }
    }

    /// The Mac's guard refuses a chat that approves everything: the machine's tab stays, the
    /// message names the setting in plain words, and "Ask first, then bring back" is offered.
    @Test func aGuardRefusalKeepsTheMachineTabWithAClearMessage() async throws {
        try await Self.withRoundTrip("policy") { trip in
            let error = try #require(await trip.bringBack(), "the bring back did not report the refusal")
            #expect(error.message == CloudBringBackStrings.policyBlocks, "\(error.message)")
            #expect(trip.calls().count == 4, "\(trip.calls())")
            #expect(trip.machineChat() != nil, "the machine's tab closed though the chat did not move")
            #expect(trip.localChat() == nil)
            #expect(trip.services.cloud.bringBackRetries[trip.machineKey] == .askFirst(machineID: "vm-move"))
        }
    }

    /// "Ask first, then bring back" (cx-rppd.10): after the Mac's guard refused a chat that approves
    /// on its own, the stop's toast offers to narrow the machine's chat to an asking policy and mode
    /// and bring it back. A plain rerun never changes the chat; the toast's action runs the move again
    /// with `--ask-first` (the machine's daemon narrows the chat before the move; this Mac's guard is
    /// unchanged), and the chat comes back.
    @Test func aGuardRefusalOffersAskFirstThenBringsTheChatBack() async throws {
        try await Self.withRoundTrip("policy") { trip in
            #expect(await trip.bringBack() != nil, "the bring back did not report the refusal")
            #expect(trip.calls().count == 4, "\(trip.calls())")
            // Bring Back Local again, not the toast's action: refused again, the chat left as it is.
            #expect(await trip.bringBack() != nil, "a plain rerun brought the chat back")
            #expect(trip.calls().count == 6, "\(trip.calls())")
            #expect(trip.calls().last?.contains("--ask-first") == false, "a plain rerun narrowed the chat: \(trip.calls())")
            #expect(trip.machineChat() != nil, "the machine's tab closed though the chat did not move")
            // The toast's "Ask first, then bring back" (``CloudBringBack/askFirstInvocation(tab:)``).
            let askFirst = ActionInvocation(target: ActionTargetRef(kind: .tab, id: trip.machineKey), arguments: ["askFirst": .bool(true)], origin: .user)
            #expect(trip.services.registry.perform(CloudBringBack.action, invocation: askFirst))
            try await trip.waitUntil { trip.localChat() != nil && trip.machineChat() == nil }
            let calls = trip.calls()
            #expect(calls.count == 8, "\(calls)")
            #expect(calls.last == ["link", "agent", "move", "--from-socket", trip.vmSocket, "--surface", String(trip.machineSurface),
                                   "--to-socket", trip.macSocket, "--cwd", trip.project.path, "--interrupt",
                                   "--sync", "pull", "--sync-socket", trip.vmSocket, "--sync-local", trip.project.path,
                                   "--sync-remote", trip.synced, "--ask-first"])
            #expect(trip.localChat()?.agentSession?.session == "chat-live")
            #expect(trip.services.cloud.bringBackRetries[trip.machineKey] == nil)
        }
    }

    /// The move back committed but the chat's tab here didn't open: the machine tab keeps its
    /// Bring Back Local row, also after a relaunch (which forgets in-memory retries), and running
    /// it again only opens the tab, without pulling or moving again.
    @Test func aCommittedBringBackWhoseTabFailedStillOpensItAfterARelaunch() async throws {
        try await Self.withRoundTrip("back") { trip in
            // No host id for this Mac: the tab can't open (the id file is unreadable).
            let tabs = trip.services.agentTabs, host = tabs.localHost, resolve = tabs.resolveLocalHost
            tabs.resolveLocalHost = { nil }
            tabs.localHost = nil
            #expect(await trip.bringBack() != nil, "the bring back did not report the tab that failed")
            #expect(trip.calls().count == 4, "\(trip.calls())")
            trip.services.cloud.bringBackRetries[trip.machineKey] = nil
            tabs.resolveLocalHost = resolve
            tabs.localHost = host
            let record = try #require(trip.machineChat()?.agentSession)
            #expect(!CloudBringBack.hiddenMenuItems(record, movedChats: trip.services.cloud.movedChats).contains(CloudBringBack.action),
                    "the machine tab lost its Bring Back Local row")
            if let error = await trip.bringBack() { Issue.record("cmux cloud bring-back again: \(error.code) \(error.message)") }
            try await trip.waitUntil { trip.localChat() != nil && trip.machineChat() == nil }
            #expect(trip.calls().count == 4, "it pulled or moved again: \(trip.calls())")
            #expect(trip.localChat()?.agentSession?.session == "chat-live")
            #expect(trip.machineChat() == nil, "the machine's tab is still open")
        }
    }

    /// A sync pull that throws (the CLI timed out) keeps the machine's tab and the bring back
    /// retryable on the same machine (cx-rppd.8).
    @Test func aSyncPullThatThrowsKeepsTheBringBackRetryable() async throws {
        try await Self.withRoundTrip("pullTimeout") { trip in
            #expect(await trip.bringBack() != nil, "the bring back did not report that it stopped")
            #expect(trip.calls().count == 3, "\(trip.calls())")
            #expect(trip.machineChat() != nil)
            #expect(trip.services.cloud.bringBackRetries[trip.machineKey] == .move(machineID: "vm-move"))
        }
    }

    // MARK: The harness

    /// One round trip's world: a chat moved from this Mac to a Cloud machine, and the stand-in CLI.
    @MainActor
    final class Trip {
        let services: AppServices
        let machine: CloudMachineSession
        let project: URL
        let log: URL
        let vmSocket: String
        var macSocket = ""
        /// The synced folder on the machine (`cmux link sync push`'s target).
        var synced = ""
        /// The moved chat's tab on the machine, as the app keys it, and its surface there.
        var machineKey = ""
        var machineSurface: UInt64 = 0

        init(services: AppServices, machine: CloudMachineSession, project: URL, log: URL, vmSocket: String) {
            self.services = services
            self.machine = machine
            self.project = project
            self.log = log
            self.vmSocket = vmSocket
        }

        /// The folder this round trip's world lives in.
        var root: URL { log.deletingLastPathComponent() }

        /// Every regular file under ``root`` (both daemons' state and logs, the CLI's log) holding `text`.
        func filesHolding(_ text: String) -> [String] {
            let needle = Data(text.utf8)
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])?.compactMap { $0 as? URL } ?? []
            return files.filter { url in
                (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                    && (try? Data(contentsOf: url))?.range(of: needle) != nil
            }.map(\.path)
        }

        /// The machine's chat tab, if it has one.
        func machineChat() -> TabModel? { Self.chat(in: machine.daemon.store) }

        /// This Mac's chat tab, if it has one.
        func localChat() -> TabModel? { Self.chat(in: services.daemon.store) }

        /// A tab bound to a chat's session; a new chat's empty tab (no session yet) is not one.
        private static func chat(in store: DaemonStore) -> TabModel? {
            store.workspaces.lazy.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).first { $0.agentSession?.session != nil }
        }

        /// The stand-in CLI's calls, but `link access`: those are polled on their own (``accessCalls()``).
        func calls() -> [[String]] { allCalls().filter { $0.prefix(2) != ["link", "access"] } }

        /// The stand-in CLI's `link access` calls: a moved chat's file requests and grants.
        func accessCalls() -> [[String]] { allCalls().filter { $0.prefix(2) == ["link", "access"] } }

        private func allCalls() -> [[String]] {
            let lines = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            return lines.split(separator: "\n").map { $0.split(separator: "\u{1f}").map(String.init) }
        }

        /// The tool cards the machine chat's page gets (its `toolCards` event), once there are some
        /// (or twenty seconds passed); nil when the chat has no page.
        func toolCards(waiting: Bool = true) async -> [[String: CmuxNextSettings.JSONValue]]? {
            let deadline = ContinuousClock.now + .seconds(20)
            func cards() -> [[String: CmuxNextSettings.JSONValue]]? {
                guard let view = services.agentTabs.existingView(machineKey) else { return nil }
                guard let event = AgentPanePageHost.currentEvents(view).first(where: { $0.kind == "toolCards" }), case .array(let list) = event.value else { return [] }
                return list.compactMap { value -> [String: CmuxNextSettings.JSONValue]? in
                    guard case .object(let card) = value else { return nil }
                    return card
                }
            }
            while waiting, cards()?.isEmpty != false, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
            return cards()
        }

        /// A click on `action` of card `card` in the machine chat's page, after a real click in the pane when
        /// `gesture`, with what the person typed in the card's field (`value`), if anything.
        func answer(_ card: String, _ action: String, gesture: Bool, value: String? = nil) async -> [String: Any] {
            guard let model = services.agentTabs.existingView(machineKey)?.model else { return ["ok": false] }
            if gesture { model.transport.gestures.record() }
            var params: [String: Any] = ["id": card, "action": action]
            if let value { params["value"] = value }
            return await model.respond(to: AgentPaneRequest(body: ["method": "chat.toolCard.respond", "params": params]))
        }

        /// The page's `chat.upload` of `files` (`{name, data}`, base64) in the machine chat's page, which
        /// is shown as for a drop, after a real gesture in the pane when `gesture`.
        func upload(_ files: [[String: Any]], gesture: Bool) async -> [String: Any] {
            guard let model = services.agentTabs.view(for: machineKey)?.model else { return ["ok": false] }
            if gesture { model.transport.gestures.record() }
            return await model.respond(to: AgentPaneRequest(body: ["method": "chat.upload", "params": ["files": files]]))
        }

        /// `cmux <action>` on tab `tab`, as the CLI sends it; its error when it stopped.
        func run(_ action: String, tab: String, args: [String: CmuxNextSettings.JSONValue] = [:], wait: Bool = true) async -> ControlError? {
            await CloudCLIActionRun(services: services)(["action": .string(action), "cli": .bool(true), "origin": .string("cli"),
                                                         "wait": .bool(wait), "target": .string("tab:" + tab), "args": .object(args)])
        }

        /// `cmux cloud bring-back` on the machine's chat tab.
        func bringBack() async -> ControlError? { await run("cloud bring-back", tab: machineKey) }

        /// Polls `condition` for up to a minute.
        func waitUntil(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(60)
            while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        }
    }

    /// Runs `body` once a live chat of this Mac moved to a connected Cloud machine; the stand-in CLI
    /// answers the bring back as `mode` says (`back`, `conflict`, `policy`, `pullTimeout`; `access` also
    /// has the chat ask for a file, `secret` for a secret; `revokeOnce` fails the first `link access revoke`).
    private static func withRoundTrip(_ mode: String, _ body: (Trip) async throws -> Void) async throws {
        let timer = PhaseTimer("back")
        let binary = try #require(SameTreeDaemonBinary.url)
        let root = URL(fileURLWithPath: "/private/tmp/cn-back-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let workRoot = root.appendingPathComponent("vm-home/work", isDirectory: true)
        try FileManager.default.createDirectory(at: workRoot, withIntermediateDirectories: true)
        let log = root.appendingPathComponent("cli.log")
        let cli = try standInCLI(in: root, log: log, mode: mode, vmState: root.appendingPathComponent("vm-state"))

        let environment: @Sendable () -> [String: String] = {
            ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh", "TERM": "xterm-256color"]
        }
        let mac = DaemonLauncher(configuration: .init(binary: binary, session: "cn-back-mac-\(UUID().uuidString.prefix(6).lowercased())",
                                                      stateDirectory: root.appendingPathComponent("mac-state")), environment: environment)
        let vm = DaemonLauncher(configuration: .init(binary: binary, session: "cn-back-vm-\(UUID().uuidString.prefix(6).lowercased())",
                                                     stateDirectory: root.appendingPathComponent("vm-state")), environment: environment)
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        services.cloud.move = CloudMoveSetup(cli: cli, workRoots: [workRoot.path], timeout: .seconds(5))
        services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-back-test")
        services.daemon.start {
            DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil), endpointProvider: mac.endpointProvider)
        }
        services.windows.restoreWhenLoaded()
        let watches = [timer.watch("restored") { services.windows.restored }, timer.watch("mac-connected") { services.daemon.connection != nil }]
        defer { for watch in watches { watch.cancel() } }
        let vmSocket = try await vm.endpointProvider().socketPath
        timer.mark("vm-endpoint")
        let machine = CloudMoveTests.machine(services, cli: cli, root: root)
        services.machines.add(machine)
        machine.daemon.start(remote: { vmSocket })

        let trip = Trip(services: services, machine: machine, project: project, log: log, vmSocket: vmSocket)
        let result: Result<Void, any Error>
        do {
            try await moveToCloud(trip, timer)
            try await body(trip)
            timer.mark("body")
            result = .success(())
        } catch {
            result = .failure(error)
            timer.mark("body-threw")
        }
        await CloudMoveTests.end(services.daemon)
        await CloudMoveTests.end(machine.daemon)
        for controller in services.windows.controllers { controller.window?.close() }
        timer.mark("ended")
        try result.get()
    }

    /// Opens a live chat in this Mac's first workspace and moves it to the machine with
    /// `cmux cloud move`, as a person would before bringing it back.
    private static func moveToCloud(_ trip: Trip, _ timer: PhaseTimer) async throws {
        let services = trip.services, machine = trip.machine
        let deadline = ContinuousClock.now + .seconds(60)
        func ready() -> Bool {
            services.daemon.store.workspaces.contains { $0.screens.contains { !$0.panes.isEmpty } }
                && machine.daemon.connection != nil && AgentTabStore.registryHost(of: machine.daemon) != nil
        }
        while !ready(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        try #require(ready(), "the daemons did not come up")
        timer.mark("daemons-ready")
        trip.macSocket = await services.daemon.connection?.endpoint?.socketPath ?? ""
        let connection = try #require(services.daemon.connection)
        let pane = try #require(services.daemon.store.workspaces.first?.screens.first?.panes.first)
        let record = AgentSessionRef(host: try #require(services.agentTabs.localHost), hostName: "This Mac", session: "chat-live", harness: "claude")
        let created = try await connection.request(NewConversationTabRequest(agentSession: record, pane: pane.handle))
        let tabID = created.tabResourceID?.rawValue ?? "surface:\(created.surface.rawValue)"
        while services.locateTab(tabID, onMachine: services.machines.local.machineID) == nil, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        timer.mark("chat-tab")
        // Setup only needs the moved chat; waiting for the full move action
        // couples setup to the control deadline and turns slow daemon startup
        // into a false timeout.
        if let error = await trip.run("cloud move", tab: tabID, args: ["path": .string(trip.project.path)], wait: false) {
            Issue.record("cmux cloud move: \(error.code) \(error.message)")
        }
        try await trip.waitUntil { trip.machineChat() != nil && trip.localChat() == nil }
        timer.mark("moved calls=\(trip.calls().count)")
        let moved = try #require(trip.machineChat(), "the chat did not move to the machine")
        trip.machineKey = moved.id
        trip.machineSurface = moved.surface.rawValue
        trip.synced = try #require(trip.calls().first?.last)
    }

    /// A stand-in `cmux` (calls recorded unit-separated): `link sync push` makes the synced folder
    /// and `link agent move` moves the chat to the machine, leaving the landed chat's record as the
    /// machine daemon's `agent-transfer-finish` would (see ``CloudMoveTests``); then `link sync
    /// pull` and the move back answer as `mode` says. `link access triage` lists one file ask of the
    /// moved chat in `access` mode, and one secret ask in `secret` mode, until `link access answer`
    /// answered it; a secret's answer keeps only the SHA-256 of its stdin (written whole, last), and an upload only the
    /// SHA-256 of its last file. Other `link access` calls answer ok.
    private static func standInCLI(in root: URL, log: URL, mode: String, vmState: URL) throws -> URL {
        let url = root.appendingPathComponent("cmux")
        let pulled = root.appendingPathComponent("pulled").path
        let answered = root.appendingPathComponent("answered").path
        let revokedOnce = root.appendingPathComponent("revoked-once").path
        let secretDigest = root.appendingPathComponent("secret-digest").path
        let uploadDigest = root.appendingPathComponent("upload-digest").path
        let project = root.appendingPathComponent("proj").path, plan = project + "/plan.md"
        let script = """
            #!/bin/sh
            line=""
            for arg in "$@"; do line="$line$(printf '\\037')$arg"; done
            printf '%s\\n' "${line#?}" >> '\(log.path)'
            case "$1 $2 $3" in
            "link sync push")
                for target in "$@"; do :; done
                mkdir -p "$target"
                echo '{"ok":true,"written":1,"unchanged":0,"deleted":0,"skipped":0,"bytes":4}' ;;
            "link sync pull")
                case '\(mode)' in
                conflict) echo '{"ok":false,"error":"notes.txt changed both here and on the machine","error_code":"sync_conflict","conflicts":["notes.txt"]}'; exit 1 ;;
                outdated) echo '{"ok":false,"error":"the machine runs an older cmux-tui (0000old) without fs-v1; update the machine","error_code":"machine_outdated","missing":["fs-v1"],"machine_build":"0000old"}'; exit 1 ;;
                updates)
                    if [ ! -e '\(root.path)/updated' ]; then
                        echo '{"ok":false,"error":"the machine runs an older cmux-tui (0000old) without fs-v1; update the machine","error_code":"machine_outdated"}'
                        exit 1
                    fi
                    touch '\(pulled)'; echo '{"ok":true,"written":1,"unchanged":0,"deleted":0,"skipped":0,"bytes":4,"fast_forwarded":true,"head":null}' ;;
                pullTimeout) exec sleep 30 ;;
                *) touch '\(pulled)'; echo '{"ok":true,"written":1,"unchanged":0,"deleted":0,"skipped":0,"bytes":4,"fast_forwarded":true,"head":null}' ;;
                esac ;;
            "link machine update")
                [ '\(mode)' = updates ] || exit 64
                : > '\(root.path)/updated'
                echo '{"ok":true,"updated":true,"build":"new","previous_build":"0000old"}' ;;
            "link agent move")
                if [ ! -f '\(pulled)' ]; then
                    registry=$(find '\(vmState.path)' -name workspace-registry.sqlite3 -print | head -n 1)
                    [ -n "$registry" ] || exit 70
                    printf '[{"session":"chat-on-vm","landed_at_ms":%s000}]' "$(date +%s)" > "$(dirname "$registry")/agent-transfer-landed.json"
                    echo '{"ok":true,"session_id":"chat-on-vm","transfer_id":"tr-1","bytes":42,"resolved":false}'
                elif [ '\(mode)' = policy ] && [ "${12}" != --ask-first ]; then
                    echo '{"ok":false,"error":"the machine did not take the chat: acpmux refused the request: transfer.policy: approve-all","error_code":"agent_transfer.refused"}'
                    exit 1
                else
                    echo '{"ok":true,"session_id":"chat-live","transfer_id":"tr-back","bytes":42,"resolved":false}'
                fi ;;
            "link access triage")
                if [ '\(mode)' = access ] && [ ! -f '\(answered)' ]; then
                    echo '{"ok":true,"answered":[],"ask":[{"request_id":"0123456789abcdef0123456789abcdef","session":"chat-on-vm","kind":"file","path":"\(plan)","reason":"to read the plan","exists":true,"shareable":true,"target":"\(plan)","folder":false,"always_folder":"\(project)"}],"errors":[]}'
                elif [ '\(mode)' = secret ] && [ ! -f '\(answered)' ]; then
                    echo '{"ok":true,"answered":[],"ask":[{"request_id":"fedcba9876543210fedcba9876543210","session":"chat-on-vm","kind":"secret","name":"GITHUB_TOKEN","reason":"to open a pull request"}],"errors":[]}'
                else
                    echo '{"ok":true,"answered":[],"ask":[],"errors":[]}'
                fi ;;
            "link access answer")
                # A slow CLI: its call is logged a second before it has read stdin (a loaded test host).
                # The digest appears whole, by rename, only once stdin was read to its end.
                case " $* " in *" --share-secret "*) sleep 1; /usr/bin/openssl dgst -sha256 -r 2> '\(secretDigest).err' | cut -d ' ' -f 1 > '\(secretDigest).part' && mv '\(secretDigest).part' '\(secretDigest)' ;; esac
                touch '\(answered)'; echo '{"ok":true}' ;;
            "link access sync") echo '{"ok":true,"synced":[]}' ;;
            "link access upload")
                for file in "$@"; do :; done
                /usr/bin/openssl dgst -sha256 -r "$file" 2> '\(uploadDigest).err' | cut -d ' ' -f 1 > '\(uploadDigest)'
                printf '{"ok":true,"uploads":[{"file":"%s","path":"%s/local/uploads/0123456789abcdef0123456789abcdef/%s"}]}\n' "$file" "$7" "$(basename "$file")" ;;
            "link access revoke")
                if [ '\(mode)' = revokeOnce ] && [ ! -f '\(revokedOnce)' ]; then
                    touch '\(revokedOnce)'; echo '{"ok":false,"error":"the machine did not answer","error_code":"link_error"}'; exit 1
                fi
                echo '{"ok":true}' ;;
            *) exit 64 ;;
            esac

            """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
