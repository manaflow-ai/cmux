#if os(iOS)
import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileAgentChat

/// Leo, 2026-11-24: "holy shit this is a huge problem in ios... wer need to chase all these
/// placeholders doen and prevent them". A chat screen the phone has seen before draws what it
/// last had and updates in place; a placeholder shows only when nothing was ever kept.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1))) struct ChatDrawsKeptNotLoadingTests {
    static let at = Date(timeIntervalSince1970: 1_700_000_000)

    static func summary(_ id: String) -> AgentSessionSummary {
        AgentSessionSummary(id: id, name: "S", harness: "claude", agentName: "Claude", cwd: "~",
                            workspaceTitle: "w", macName: "m", macID: "mac-1")
    }

    /// A chat whose recorded history arrives when the test lets it.
    final class GatedReplay: AgentSessionSource {
        let summary: AgentSessionSummary
        var answer: AgentReplayRecording
        private var waiting: [CheckedContinuation<Void, Never>] = []
        init(id: String, answer: AgentReplayRecording) {
            summary = ChatDrawsKeptNotLoadingTests.summary(id)
            self.answer = answer
        }
        func events() -> AsyncStream<AgentSessionEvent> { AsyncStream { _ in } }
        func send(_ intent: AgentClientIntent) {}
        func replayRecording() async throws -> AgentReplayRecording {
            await withCheckedContinuation { waiting.append($0) }
            return answer
        }
        func release() {
            let all = waiting
            waiting = []
            for continuation in all { continuation.resume() }
        }
        var isWaiting: Bool { !waiting.isEmpty }
    }

    static func recording(prompts: Int) -> AgentReplayRecording {
        AgentReplayRecording(steps: (0 ..< prompts).map { n in
            .init(time: TimeInterval(n),
                  events: [.userMessage(text: "prompt \(n)", promptId: "p\(n)", turnId: "t\(n)", attachments: [], at: at)],
                  isToolCall: false)
        }, truncated: false)
    }

    func settle(_ done: () -> Bool) async {
        // The suite's time limit bounds a hang.
        while !done(), !Task.isCancelled { await Task.yield() } // test: polls the condition
    }

    /// Replay Conversation opened again plays the recording it had at once, before the Mac's copy
    /// is read: no "Loading this chat's history…" over a chat replayed before.
    @Test func aReplayOpenedAgainDrawsItsKeptRecordingWhileTheMacsIsRead() async {
        ChatReplayPlayer.forgetKept()
        defer { ChatReplayPlayer.forgetKept() }
        let source = GatedReplay(id: "replay-kept-\(UUID().uuidString)", answer: Self.recording(prompts: 3))
        let chat = AgentChatStore(source: source)

        let first = ChatReplayPlayer()
        let firstLoad = Task { await first.load(chat) }
        await settle { source.isWaiting }
        #expect(first.state == .loading, "never replayed: nothing kept stands in")
        source.release()
        await firstLoad.value
        #expect(first.state == .ready)
        first.pause()

        // Opened again: ready on the kept recording while the Mac is still asked.
        source.answer = Self.recording(prompts: 5)
        let again = ChatReplayPlayer()
        let againLoad = Task { await again.load(chat) }
        await settle { source.isWaiting }
        #expect(again.state == .ready, "the kept recording, not a spinner")
        #expect(again.recording.steps.count == 3)
        #expect(again.store != nil)
        // The Mac's newer copy takes its place in the same screen.
        source.release()
        await againLoad.value
        #expect(again.state == .ready)
        #expect(again.recording.steps.count == 5)
        again.pause()
    }

    /// A failed read of a replay that had a kept recording keeps it on screen.
    @Test func aFailedReadKeepsTheKeptRecording() async {
        ChatReplayPlayer.forgetKept()
        defer { ChatReplayPlayer.forgetKept() }
        let summary = Self.summary("replay-fail-\(UUID().uuidString)")
        ChatReplayPlayer.keep(Self.recording(prompts: 2), for: AgentSessionDirectory.key(id: summary.id, macID: summary.macID))
        // A replay source reads no recording (the protocol's default throws).
        let chat = AgentChatStore(source: ReplaySource(summary: summary))
        let player = ChatReplayPlayer()
        await player.load(chat)
        #expect(player.state == .ready, "the kept recording stays; the error is not drawn over it")
        #expect(player.recording.steps.count == 2)
        player.pause()
    }

    /// The kept recordings are bounded and dropped at sign-out.
    @Test func keptRecordingsAreBoundedAndForgotten() {
        ChatReplayPlayer.forgetKept()
        let last = "k\(ChatReplayPlayer.keptLimit + 1)"
        for n in 0 ... ChatReplayPlayer.keptLimit + 1 { ChatReplayPlayer.keep(Self.recording(prompts: 1), for: "k\(n)") }
        #expect(ChatReplayPlayer.keptRecording("k0") == nil)
        #expect(ChatReplayPlayer.keptRecording(last) != nil)
        AgentSessionDirectory().removeAll()
        #expect(ChatReplayPlayer.keptRecording(last) == nil)
    }

    /// A chat opened before the live list holds its workspace (a cold open from a notification)
    /// resolves the tab from the copy this phone saved, while the list loads; a live list that
    /// lacks it goes to the closed grace, not to the saved copy.
    @Test func aChatOpenedWhileTheListLoadsResolvesItsSavedTab() {
        let tab = WorkspaceTab(id: "s7", kind: .agent, title: "Claude", harness: "claude")
        let saved = Workspace(id: "w9", macID: "mac-1", title: "cmux", directory: "~/cmux", tabs: [tab], lastActivityAt: Self.at)
        let store = AppStore(teams: [], activeTeamID: "", workspaces: [], feed: [], tabMemory: .inMemory())
        store.savedWorkspace = { $0 == saved.id ? saved : nil }
        let destination = AgentChatDestination(workspaceID: "w9", tabID: "s7")

        let found = AgentChatDestinationView.savedTab(destination, in: store, loading: true)
        #expect(found?.workspace.id == "w9")
        #expect(found?.tab.id == "s7")
        #expect(AgentChatDestinationView.savedTab(destination, in: store, loading: false) == nil,
                "a loaded list that lacks the tab: the closed grace decides")
        #expect(AgentChatDestinationView.savedTab(AgentChatDestination(workspaceID: "w9", tabID: "gone"), in: store, loading: true) == nil)
        #expect(AgentChatDestinationView.savedTab(AgentChatDestination(workspaceID: "never", tabID: "s7"), in: store, loading: true) == nil,
                "never saved: the placeholder is the only thing to draw")
    }

    /// An expanded tool call whose output the Mac cut keeps its head drawn while the rest is read:
    /// no "Loading the full output…" line comes and goes under it (the card keeps its height).
    @Test func aCutToolOutputDrawsNoLoadingLine() {
        #expect(!ToolOutputFooter.shows(cut: true, failed: false), "reading the rest: the head stands, no line")
        #expect(!ToolOutputFooter.shows(cut: false, failed: false))
        #expect(ToolOutputFooter.shows(cut: true, failed: true), "a failed read offers Try Again")
    }
}
#endif
