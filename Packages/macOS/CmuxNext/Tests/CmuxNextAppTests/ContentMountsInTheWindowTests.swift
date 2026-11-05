import AppKit
@testable import CmuxNextApp
import CmuxNextAgentPane
import CmuxNextAppCore
import CmuxNextDaemon
@testable import CmuxNextLayout
import Foundation
import Testing

/// A workspace the window shows for the first time (Cmd-N's stand-in) lays its screen out once, in the window, at the
/// window's size. Its content controller ran its first apply before the window showed its view: the panes mounted
/// outside the window (a Chromium New Tab page adopted there left the window, its page window ordered out, then in
/// again), and the screen reconciled at no size, then again at the window's in the frame's layout pass, each pass
/// setting every pane host's frame (CMD-N FIRST FRAME, STATUS 13669: a 10 ms resize reconcile in the first frame).
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct ContentMountsInTheWindowTests {
    @Test func cmdNsNewScreenLaysOutOnceInTheWindowAtItsSize() async throws {
        let launched = try await RapidWorkspaceCreateTests.launch()
        let services = launched.services
        let tabs = services.agentTabs
        tabs.localHost = tabs.localHost ?? AgentSessionRef.host(installID: "content-mounts-test")
        tabs.holdsTabs = { _ in true }
        let canHost = tabs.canHostChat
        let controller = services.windows.active
        let listedBefore = Set(services.daemon.store.workspaces.map(\.id))
        var create: (() async throws -> String)?
        if canHost, let window = controller?.state.id {
            create = services.windows.startWorkspace(WorkspaceSpawn(newTabPage: true), into: window)
        }
        let standIn = services.daemon.store.workspaces.first { !listedBefore.contains($0.id) }?.id
        // Shown in the key's turn, or on the window's observation hop.
        let shown = await RapidWorkspaceCreateTests.wait(within: .seconds(5)) { standIn != nil && controller?.content?.workspace.id == standIn }
        controller?.window?.layoutIfNeeded() // the frame's layout pass
        let root = controller?.content?.layoutView
        let screen = root?.screenViews.values.first
        let passes = screen?.reconcilePasses
        let screenSize = screen?.frame.size
        let rootSize = root?.bounds.size
        _ = try? await create?()
        await launched.stop()

        try #require(canHost, "this build has no agent page")
        try #require(shown, "the window never showed the stand-in")
        try #require(screen != nil, "the stand-in's layout has no screen")
        #expect(screenSize == rootSize && (rootSize?.width ?? 0) > 0, "the screen is \(String(describing: screenSize)), its root \(String(describing: rootSize))")
        #expect(passes == 1, "the new screen reconciled \(passes ?? -1) times by its first frame's layout pass (want 1)")
    }
}
