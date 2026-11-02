#if os(iOS)
import Foundation
import Testing
@testable import CmuxMobileAgentChat

/// The Mac's chat rows the phone now runs (cmux#25834 slice C): cmux slash commands, Edit and
/// Resend of an earlier prompt (the turn its fork goes through), Resume of a paused queue,
/// and the frames a video goes with.
@MainActor
@Suite struct ChatRowsParityTests {
    final class Recorder: AgentSessionSource {
        let summary: AgentSessionSummary
        var sent: [AgentClientIntent] = []
        init(harness: String = "claude") {
            summary = AgentSessionSummary(id: "s", name: "S", harness: harness, agentName: "Claude", cwd: "~", workspaceTitle: "w", macName: "m")
        }
        func events() -> AsyncStream<AgentSessionEvent> { AsyncStream { _ in } }
        func send(_ intent: AgentClientIntent) { sent.append(intent) }
    }

    private func turn(_ store: AgentChatStore, _ id: String, _ prompt: String, _ status: AgentTurn.Status = .completed, seq: Int?) {
        store.apply(.userMessage(text: prompt, promptId: "p-\(id)", turnId: id, attachments: [], at: Date()))
        store.apply(.turnStarted(turnId: id, at: Date()))
        store.apply(.turnResult(turnId: id, status: status, errorText: status == .failed ? "boom" : nil, at: Date()))
        if let seq { store.apply(.turnSeq(turnId: id, seq: seq)) }
    }

    @Test func slashCommandsParseOnlyAloneAtTheStart() {
        #expect(CmuxSlashCommand.parse("/status")?.command == .status)
        #expect(CmuxSlashCommand.parse("  /Fork ")?.command == .fork)
        let continued = CmuxSlashCommand.parse("/continue Codex")
        #expect(continued?.command == .continue && continued?.args == "Codex")
        #expect(CmuxSlashCommand.parse("please /fork") == nil)
        #expect(CmuxSlashCommand.parse("/btw why?") == nil, "a side chat is the Mac app's only (btw.remote)")
        #expect(CmuxSlashCommand.parse("/compact") == nil, "the agent's own commands go to it as typed")
    }

    @Test func slashCommandRefusalsUseTheMacWording() {
        #expect(CmuxSlashCommand.fork.refusal(args: "x", canFork: true, isRunning: false, targets: nil) == "/fork does not take arguments")
        #expect(CmuxSlashCommand.fork.refusal(args: "", canFork: false, isRunning: false, targets: nil) == "Fork is unavailable for this chat right now")
        #expect(CmuxSlashCommand.fork.refusal(args: "", canFork: true, isRunning: true, targets: nil) != nil)
        #expect(CmuxSlashCommand.fork.refusal(args: "", canFork: true, isRunning: false, targets: nil) == nil)
        let targets = [AgentHandoffTarget(id: "codex", name: "Codex")]
        #expect(CmuxSlashCommand.continue.refusal(args: "gemini", canFork: true, isRunning: false, targets: targets) == "No matching harness for /continue")
        #expect(CmuxSlashCommand.target("codex", in: targets)?.id == "codex")
        #expect(CmuxSlashCommand.target("CODEX", in: targets)?.name == "Codex")
        #expect(CmuxSlashCommand.status.refusal(args: "", canFork: false, isRunning: true, targets: nil) == nil)
    }

    @Test func slashRunsStatusAndFallsBackToHandoffList() async {
        let store = AgentChatStore(source: Recorder())
        let surface = AgentChatSurface()
        #expect(await surface.run(.status, args: "", store: store) == nil)
        #expect(surface.showStatus)
        #expect(await surface.run(.continue, args: "", store: store) == nil)
        #expect(surface.parityRoute == .handoff)
        // No workspace tab: /fork is refused, never sent to the agent.
        #expect(await surface.run(.fork, args: "", store: store) == "Fork is unavailable for this chat right now")
    }

    @Test func slashForkRunsTheTabFork() async {
        let store = AgentChatStore(source: Recorder())
        let surface = AgentChatSurface()
        final class Count { var forks = 0 }
        let count = Count()
        surface.tabActions = AgentChatTabActions(fork: { count.forks += 1 }, editAndResend: { _, _ in false })
        #expect(await surface.run(.fork, args: "", store: store) == nil)
        #expect(count.forks == 1)
    }

    @Test func earlierPromptForksThroughTheCompletedTurnBeforeIt() {
        let store = AgentChatStore(source: Recorder())
        turn(store, "t1", "first", seq: 12)
        turn(store, "t2", "second", seq: 30)
        turn(store, "t3", "third", seq: 44)
        let turns = store.turns
        #expect(store.editForkSeq(for: turns[0]) == nil, "a chat's first prompt has no turn before it")
        #expect(store.editForkSeq(for: turns[1]) == 12)
        #expect(store.editForkSeq(for: turns[2]) == 30)
    }

    @Test func earlierPromptNeedsAnAnsweredTurnAndAForkingAgent() {
        let store = AgentChatStore(source: Recorder())
        turn(store, "t1", "first", .failed, seq: 5)
        turn(store, "t2", "second", seq: 9)
        #expect(store.editForkSeq(for: store.turns[1]) == nil, "the turn before it failed")
        let other = AgentChatStore(source: Recorder(harness: "opencode"))
        turn(other, "t1", "first", seq: 5)
        turn(other, "t2", "second", seq: 9)
        #expect(other.editForkSeq(for: other.turns[1]) == nil, "only Claude and Codex fork through an earlier turn")
        let routed = AgentChatStore(source: Recorder(harness: "claude-sr"))
        turn(routed, "t1", "first", seq: 5)
        turn(routed, "t2", "second", seq: 9)
        #expect(routed.editForkSeq(for: routed.turns[1]) == 5)
    }

    @Test func pausedQueueResumes() {
        let source = Recorder()
        let store = AgentChatStore(source: source)
        store.resumeQueue()
        #expect(source.sent.isEmpty, "nothing is held")
        store.apply(.queued(text: "next", promptId: "q1", position: 0))
        store.apply(.queuePaused(true, reason: nil))
        #expect(store.queuePaused)
        store.resumeQueue()
        #expect(source.sent == [.resumeQueue])
        store.apply(.queuePaused(false, reason: nil))
        #expect(!store.queuePaused)
        store.apply(.queuePaused(true, reason: "stop"))
        #expect(store.queuePauseReason == "stop")
    }

    @Test func videoFrameTextMatchesTheMac() {
        #expect(AgentVideo.frameTime(0) == "0:00.0")
        #expect(AgentVideo.frameTime(65_430) == "1:05.4")
        #expect(AgentVideo.frameTime(3_723_000) == "1:02:03.0")
        let video = AgentVideo(durationMs: 16_000, width: 1920, height: 1080, frames: [
            .init(atMs: 2_000, jpeg: Data([1])), .init(atMs: 6_000, jpeg: Data([2])),
        ])
        #expect(video.framesNote(name: "clip.mov") == "Frames from the video clip.mov (0:16, 1920×1080), in order, at: 0:02.0, 0:06.0.")
        #expect(AgentVideo.frameName("clip.mov", atMs: 2_000) == "clip.mov frame at 0:02.0")
        #expect(AgentVideo.isFrameName("clip.mov frame at 0:02.0"))
        #expect(!AgentVideo.isFrameName("photo.png"))
        #expect(AgentVideo.isVideoName("IMG_0001.MOV") && !AgentVideo.isVideoName("a.pdf"))
    }

    @Test func sentBubbleLeavesTheFramesTextOut() {
        let names: [String?] = ["clip.mov frame at 0:02.0", "clip.mov frame at 0:06.0"]
        let text = "Look at this\nFrames from the video clip.mov (0:16, 1920×1080), in order, at: 0:02.0, 0:06.0.\nclip.mov frame at 0:02.0\nclip.mov frame at 0:06.0"
        #expect(AgentVideo.withoutFrameText(text, imageNames: names) == "Look at this")
        // Text that only looks like a note, with no frame images in the prompt, is the person's own.
        #expect(AgentVideo.withoutFrameText("clip.mov frame at 0:02.0", imageNames: []) == "clip.mov frame at 0:02.0")
    }

    @Test func pdfIsKnownByName() {
        #expect(AgentAttachment(kind: .file, name: "Brief.PDF").isPDF)
        #expect(!AgentAttachment(kind: .image, name: "x.pdf").isPDF)
        #expect(!AgentAttachment(kind: .file, name: "notes.txt").isPDF)
    }
}
#endif
