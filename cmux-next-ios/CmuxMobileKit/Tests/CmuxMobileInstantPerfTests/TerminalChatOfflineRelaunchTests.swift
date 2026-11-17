#if os(iOS) && canImport(CmuxMobileLinkFFI)
import CmuxMobileLinkFFI
import CmuxMobileLive
import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileAgentChat
@testable import CmuxMobileWorkspaces

/// A terminal running Claude Code or Codex, opened again after a relaunch with the Mac out of reach
/// (Leo, 2026-11-14: the phone should rely less on the Mac and on a smooth network): the tab opens on
/// its terminal (#43953), and when the person opens its chat face, it shows the turns this phone kept,
/// read-only, at once. Before, the chat face needed the Mac's live chat list or this run's memory to
/// know which chat shows the session, so it spun on "Opening chat…", then fell back to the terminal
/// when the request failed.
///
/// The pairing is read from the real file the live backend keeps (`KeptTerminalChats`), off the main
/// thread, so a tap on Chat can come before the read lands: it waits for the read, never asks the
/// unreachable Mac and falls back to the terminal (#44251 follow-up).
///
/// Prints `OFFLINECHAT cold_launch_to_first_kept_turn_ms=<ms>` (or `=never`): from the tab source's
/// creation on a fresh cache and an unlinked hub to the store holding the first kept turn.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)))
struct TerminalChatOfflineRelaunchTests {
    /// A Mac's terminal chat backend: online it lists `listings`; offline it lists nothing and every
    /// request fails, as the live backend does with the link down. The pairing is kept as the live
    /// backend keeps it: in `kept`, a file on disk, keyed by account and Mac.
    @MainActor final class Backend: WorkspaceCreationBackend, TerminalChatBackend {
        let kept: KeptTerminalChats
        let listings: [TerminalChatListing]
        let online: Bool
        var asked = 0
        init(kept: KeptTerminalChats, online: Bool, listings: [TerminalChatListing] = []) {
            self.kept = kept
            self.online = online
            self.listings = listings
        }
        func canCreate(on macID: String) -> Bool { online }
        func options(on macID: String) -> WorkspaceCreationOptions { .basic }
        func create(_ request: NewWorkspaceRequest, placeholder: Workspace) async throws -> Workspace { placeholder }
        func terminalChatListings(on macID: String) -> [TerminalChatListing] { online ? listings : [] }
        func openTerminalChat(harness: String, session: String, terminalTabID: String, on macID: String) async throws -> TerminalChatOpen {
            asked += 1
            throw WorkspaceCreationError("Not connected to a Mac")
        }
        func terminalChatListedWhole(on macID: String) -> Bool { online }
        func keptTerminalChat(harness: String, session: String, on macID: String) -> String? {
            KeptTerminalChats.key("acct", macID, harness, session).flatMap { kept.chat($0) }
        }
        func keepTerminalChat(_ chat: String?, harness: String, session: String, on macID: String) {
            guard let key = KeptTerminalChats.key("acct", macID, harness, session) else { return }
            kept.keepChat(chat, for: key)
        }
        var keptTerminalChatsLoaded: Bool { kept.isLoaded }
        func loadKeptTerminalChats() async { await kept.load() }
    }

    static func terminal(_ id: String, agent: String, session: String) -> WorkspaceTab {
        var tab = WorkspaceTab(id: id, kind: .terminal, title: "zsh", subtitle: "/tmp/p", harness: agent)
        tab.linkIDs = WorkspaceTab.LinkIDs(tab: "tab_\(id)", harnessSession: session)
        return tab
    }

    static func source(_ backend: Backend, sessions: AgentSessionDirectory) -> WorkspaceTabsSource {
        let store = AppStore.mock(tabMemory: .inMemory([:]))
        store.workspaces = [Workspace(id: "w", macID: "mac", title: "relay", directory: "/tmp/p",
                                      tabs: [terminal("s1", agent: "claude-code", session: "h-1")],
                                      lastActivityAt: Date())]
        return WorkspaceTabsSource(store: store, workspaceID: "w", sessions: sessions,
                                   creator: WorkspaceCreator(store: store, backend: backend))
    }

    /// Turn `n` of chat `chat`: a prompt, its start, an answer, its result.
    static func turn(_ n: Int, chat: String) -> [String] {
        let seq = n * 4 + 1
        return [
            #"{"sessionId":"\#(chat)","seq":\#(seq),"at":1,"dir":"mux","kind":"user_message","msg":{"text":"prompt \#(n)","promptId":"p\#(n)","turnId":"t\#(n)"}}"#,
            #"{"sessionId":"\#(chat)","seq":\#(seq + 1),"at":2,"dir":"mux","kind":"turn_started","msg":{"turnId":"t\#(n)"}}"#,
            #"{"sessionId":"\#(chat)","seq":\#(seq + 2),"at":3,"dir":"in","kind":"agent_message_chunk","msg":{"method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"answer \#(n)"}}}}}"#,
            #"{"sessionId":"\#(chat)","seq":\#(seq + 3),"at":4,"dir":"mux","kind":"turn_result","msg":{"status":"completed","turnId":"t\#(n)"}}"#,
        ]
    }

    /// Chat `chat`'s first `turns` turns, as the transcript cache keeps them.
    static func kept(_ turns: Int, chat: String) throws -> AgentTranscriptEntry {
        let records = (0..<turns).flatMap { turn($0, chat: chat) }.joined(separator: ",")
        let json = #"{"sessionID":"\#(chat)","earlier":false,"records":[\#(records)]}"#
        return try JSONDecoder().decode(AgentTranscriptEntry.self, from: Data(json.utf8))
    }

    /// The live coordinator's source for a terminal's chat face: the hub's source of the chat it names.
    static func directory(_ hub: AcpmuxHub) -> AgentSessionDirectory {
        let sessions = AgentSessionDirectory()
        sessions.makeSource = { summary in
            var scoped = summary
            scoped.accountID = "acct"
            guard let chat = summary.acpmuxSessionID else { return DisconnectedAgentSource(summary: scoped) }
            return hub.source(sessionID: chat, summary: scoped)
        }
        return sessions
    }

    static func waitUntil(_ timeout: Duration = .seconds(5), _ done: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !done() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .microseconds(200)) // test: polls the condition until a deadline
        }
        return true
    }

    static func folder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "terminal-chat-offline-\(UUID().uuidString)",
                                                         directoryHint: .isDirectory)
    }

    static func cache(_ folder: URL) -> AgentTranscriptCache {
        AgentTranscriptCache(directory: folder, writeDelay: .milliseconds(0))
    }

    /// An earlier launch, online: the Mac's View Only chat a-1 shows terminal s1's session; the pairing
    /// and the chat's turns were kept on disk.
    static func keepEarlierLaunch(in folder: URL) async throws {
        let cache = Self.cache(folder)
        let watch = TerminalChatListing(sessionID: "a-1", harness: "claude", agentSessionID: "h-1", watching: true, status: "idle")
        let backend = Backend(kept: cache.terminalChats, online: true, listings: [watch])
        let source = Self.source(backend, sessions: AgentSessionDirectory())
        let workspace = try #require(source.workspace)
        let tab = try #require(source.workspaceTab("s1"))
        #expect(source.terminalChatSessionID(tab, in: workspace) == "a-1")
        source.openTerminalChatIfNeeded("s1")
        let key = try #require(AgentTranscriptCache.key(accountID: "acct", macID: "mac", tabID: "s1#chat:a-1"))
        let entry = try Self.kept(3, chat: "a-1")
        #expect(entry.records.count == 12)
        cache.save(key, sessionID: entry.sessionID, earlier: entry.earlier, records: entry.records)
        cache.flush()
        await cache.terminalChats.flush()
        let pairing = try #require(KeptTerminalChats.key("acct", "mac", "claude", "h-1"))
        #expect(cache.terminalChats.chat(pairing) == "a-1", "the earlier launch kept the pairing on disk")
    }

    @Test func aRelaunchWithTheLinkDownOpensTheAgentTabOnItsKeptTurns() async throws {
        let folder = Self.folder()
        let pairings = Self.cache(folder).terminalChats.file
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: pairings)
        }
        try await Self.keepEarlierLaunch(in: folder)

        // Relaunch with the link down: a fresh cache reads the disk, the hub has no link.
        let started = ContinuousClock.now
        let hub = AcpmuxHub()
        hub.transcriptCache = Self.cache(folder)
        let kept = Self.cache(folder).terminalChats
        let backend = Backend(kept: kept, online: false)
        let source = Self.source(backend, sessions: Self.directory(hub))
        let workspace = try #require(source.workspace)
        let tab = try #require(source.workspaceTab("s1"))
        let faces = source.pairFaces(tab, in: workspace)
        #expect(faces.offered && faces.chatEnabled && faces.defaultFace == .terminal)
        #expect(!source.showsChatFace(tab, in: workspace), "a terminal opens on its terminal")
        // The person opens the chat face: it shows the kept chat, with nothing to ask the Mac.
        source.swapTerminalChat("s1", to: .chat)
        source.openTerminalChatIfNeeded("s1")
        _ = await Self.waitUntil { kept.isLoaded && source.terminalChatSessionID(tab, in: workspace) != nil }
        #expect(source.showsChatFace(tab, in: workspace))
        guard let chat = source.terminalChatSessionID(tab, in: workspace) else {
            print("OFFLINECHAT cold_launch_to_first_kept_turn_ms=never")
            Issue.record("offline, the terminal's chat face has no chat to show: it spins on \"Opening chat…\"")
            return
        }
        #expect(chat == "a-1")
        let store = source.terminalChatStore(tab, in: workspace, chatSession: chat, faces: faces)
        let shown = await Self.waitUntil { !store.turns.isEmpty }
        let elapsed = (ContinuousClock.now - started).components
        let ms = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        let line = "OFFLINECHAT cold_launch_to_first_kept_turn_ms=\(shown ? String(format: "%.2f", ms) : "never")"
        print(line)
        // The kit run keeps attachments, not a passing test's console.
        Attachment.record(line, named: "offlinechat.txt")
        #expect(shown)
        _ = await Self.waitUntil { store.turns.count == 3 }
        #expect(store.turns.map(\.id) == ["t0", "t1", "t2"])
        // Read-only and offline: the store says so (the chat face takes no prompt).
        #expect(store.isOffline)
        #expect(backend.asked == 0)
        #expect(source.showsChatFace(tab, in: workspace))
    }

    /// The pairing file is read off the main thread at launch. A tap on Chat before that read lands
    /// waits for it: the chat face opens on the kept chat. Before, the tab asked the unreachable Mac
    /// for a new chat at once, the request failed, and the tab fell back to its terminal.
    @Test func chatTappedBeforeThePairingIsReadOpensTheKeptChat() async throws {
        let folder = Self.folder()
        let pairings = Self.cache(folder).terminalChats.file
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: pairings)
        }
        try await Self.keepEarlierLaunch(in: folder)

        // Relaunch with the link down, on a disk that holds the pairing file's read until released.
        let disk = DispatchQueue(label: "terminal-chat-offline-slow-disk")
        disk.suspend()
        let kept = KeptTerminalChats(file: pairings, queue: disk)
        let hub = AcpmuxHub()
        hub.transcriptCache = Self.cache(folder)
        let backend = Backend(kept: kept, online: false)
        let source = Self.source(backend, sessions: Self.directory(hub))
        let workspace = try #require(source.workspace)
        let tab = try #require(source.workspaceTab("s1"))
        source.swapTerminalChat("s1", to: .chat)
        source.openTerminalChatIfNeeded("s1")
        // The read has not landed: nothing may ask the Mac in the meantime.
        let askedEarly = await Self.waitUntil(.milliseconds(300)) { backend.asked > 0 }
        let loadedEarly = kept.isLoaded
        disk.resume()
        #expect(!loadedEarly, "the pairing read is held on the disk")
        #expect(!askedEarly, "a tap on Chat before the pairing read asked the unreachable Mac")

        let paired = await Self.waitUntil { kept.isLoaded && source.terminalChatSessionID(tab, in: workspace) != nil }
        #expect(paired)
        // Any request the tap started has run by now.
        _ = await Self.waitUntil(.milliseconds(100)) { backend.asked > 0 }
        #expect(source.terminalChatSessionID(tab, in: workspace) == "a-1")
        #expect(source.showsChatFace(tab, in: workspace), "the tab fell back to its terminal")
        #expect(backend.asked == 0)
    }
}
#endif
