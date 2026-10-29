import AppKit
@testable import CmuxNextTerminal
import CmuxNextWakeups
import Foundation
import Testing

/// What a hidden terminal holds (feature `terminalHiddenActionHold`) reaches its
/// session's model before a reader that does not depend on visibility: a surface swap, whose old surface
/// takes its mailbox with it, and a save at quit (`RemoteTerminalService.saveSnapshot`).
@MainActor @Suite(.serialized) struct TerminalHiddenActionHoldTests {
    @Test func aHeldWorkingDirectoryOutlivesASurfaceSwap() async throws {
        let (session, io, restore) = try Self.hiddenSession()
        defer { session.close(); io.finish(); restore() }
        try await Self.replay(session, io, replay: "before\r\n")
        let old = session.surfaceView

        #expect(old.bridgeObject.deliver(.pwd("/tmp/held"), runtime: nil))
        #expect(old.bridgeObject.actionMailbox.isHeld, "nobody sees the tab: the pwd waits")
        #expect(session.model.workingDirectory == nil)

        try await Self.replay(session, io, replay: "after\r\n")

        #expect(session.surfaceView !== old)
        #expect(session.model.workingDirectory == "/tmp/held", "the held pwd went with the old surface")
        #expect(session.surfaceView.bridgeObject.linkFilter.workingDirectory == "/tmp/held",
                "the fresh surface resolves relative links from the old folder")
    }

    @Test func applyingWaitingActionsSetsAHiddenTerminalsTitleAndHeldState() throws {
        let (session, io, restore) = try Self.hiddenSession()
        defer { session.close(); io.finish(); restore() }
        let bridge = session.surfaceView.bridgeObject
        _ = bridge.deliver(.pwd("/tmp/held"), runtime: nil)
        _ = bridge.deliver(.setTitle("new title"), runtime: nil)
        #expect(session.model.title != "new title", "the title waits for the frame")

        session.applyWaitingActions() // what the quit snapshot calls before it reads the title

        #expect(session.model.title == "new title")
        #expect(session.model.workingDirectory == "/tmp/held")
        #expect(bridge.actionMailbox.pendingCount == 0)
    }

    /// A session in a hidden tab, with the runtime holding hidden terminals' actions; `restore` puts the
    /// runtime's setting back.
    private static func hiddenSession() throws -> (TerminalSession, ScriptedTerminalIO, () -> Void) {
        _ = NSApplication.shared
        GhosttyRuntime.startedForTests()
        let runtime = GhosttyRuntime.shared
        let held = runtime.holdsHiddenActions
        runtime.holdsHiddenActions = true
        let io = ScriptedTerminalIO(answersTerminalQueries: false)
        let session = TerminalSession(io: io, mainWork: MainWorkScheduler(budget: MainFrameBudget()),
                                      node: VisibilityNode(root: "tab", own: .hidden))
        try #require(session.surfaceView.surface != nil, "libghostty created no surface")
        return (session, io, { runtime.holdsHiddenActions = held })
    }

    /// Sends `replay` and waits (5 s at most) until the session parsed it: a session with content swaps
    /// in a new surface for it.
    private static func replay(_ session: TerminalSession, _ io: ScriptedTerminalIO, replay: String) async throws {
        let before = session.surfaceView
        let hadContent = session.surfaceHasContent
        io.send(.replay(Data(replay.utf8)))
        let by = ContinuousClock.now.advanced(by: .seconds(5))
        while hadContent ? session.surfaceView === before : !session.surfaceHasContent, ContinuousClock.now < by {
            await Task.yield()
        }
        try #require(hadContent ? session.surfaceView !== before : session.surfaceHasContent, "the replay was not applied")
    }
}
