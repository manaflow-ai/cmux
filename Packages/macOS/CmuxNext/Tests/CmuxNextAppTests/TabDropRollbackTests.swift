import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextTabs
import Testing

/// A failed drop must restore the source and remove its destination preview,
/// including failures before a move can find its source tab or destination pane.
@MainActor
struct TabDropRollbackTests {
    final class Strip {
        let model = TabStripModel(tabs: [TabItem(id: "target", title: "Target")], selectedID: "target")
        let view: TabStripView
        let window: NSWindow

        init() {
            _ = NSApplication.shared
            view = TabStripView(model: model)
            window = NSWindow(contentRect: NSRect(x: 200, y: 150, width: 700, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            view.layoutSubtreeIfNeeded()
        }

        var point: CGPoint {
            window.convertPoint(toScreen: view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil))
        }

        func preview(_ id: String = "dragged") throws -> TabDropProposal {
            try #require(view.dropHitTest(screenPoint: point, payload: .tab(id: id, sourceStripID: UUID())))
        }
    }

    @Test func aRejectedDropDoesNotKeepTheCommittedPhantom() throws {
        let strip = Strip()
        defer { strip.window.close() }
        let proposal = try strip.preview()
        let services = AppServices(environment: AppEnvironment.current([:]))
        let session = services.dragSession
        let frame = proposal.highlightFrame
        let ghost = TabDragGhostPanel(tabImage: nil, tabSize: frame.size, grabOffset: .zero, aspect: nil, scale: 2, onGlass: false)
        let source = TabDragSession.Source(item: .tab("dragged"), payload: .tab(id: "dragged", sourceStripID: UUID()),
                                           screenFrame: frame, grabOffset: .zero, tabOffset: .zero, windowSize: strip.window.frame.size,
                                           context: TabDragContext(sourcePaneID: "source", sourcePaneTabCount: 2,
                                                                   sourceWorkspaceID: "workspace", sourceWorkspaceTabCount: 2, draggedTabCount: 1))
        var restores = 0
        let lifecycle = TabDragLifecycle(restore: { restores += 1 })
        let drag = TabDragSession.Drag(source: source, lifecycle: lifecycle, ghost: ghost,
                                       motion: TabDragGhostMotion(rect: frame, cardness: 0, reduceMotion: true), point: strip.point)
        drag.winner = TabDragSession.Winner(provider: strip.view, proposal: proposal)
        drag.outcome = .strip(stripID: strip.model.stripID, index: 1, groupID: nil)
        drag.resolution = TabDropResolution(preview: .target(proposal), outcome: drag.outcome)
        drag.touched[ObjectIdentifier(strip.view)] = strip.view
        session.drag = drag
        // The source disappeared after previewing: execute fails before the
        // target pane's normal move callback can resync the strip.
        session.finish(commit: true)
        #expect(lifecycle.phase == .restored)
        #expect(restores == 1)
        #expect(strip.view.pendingDrop == nil)
        #expect(strip.view.dropPlaceholderIndex == nil)
        #expect(strip.view.dropPlaceholderGroup == nil)
        #expect(strip.view.displayedOrder == ["target"])
        #expect(session.drag == nil && session.landing == nil && session.commitsInFlight.isEmpty)
        #expect(!ghost.panel.isVisible)
    }

    @Test func aPaneResyncDoesNotCancelAnUncommittedDropPreview() throws {
        let snapshot = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, title: "Target")])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [snapshot])
        let shown = try PaneCloseControllerTests.Shown(tree: DaemonTree(workspaces: [
            WorkspaceSnapshot(id: 1, key: nil, name: "w1", screens: [screen]),
        ]))
        defer { shown.end() }
        let pane = try shown.controller(1)
        let strip = pane.view.stripView
        strip.syncFromModel()
        let point = shown.window.convertPoint(toScreen: strip.convert(CGPoint(x: strip.bounds.midX, y: strip.bounds.midY), to: nil))
        let proposal = try #require(strip.dropHitTest(screenPoint: point, payload: .tab(id: "incoming", sourceStripID: UUID())))
        let before = strip.dropPlaceholderIndex
        try #require(before != nil)
        // Any rejected pane action can request this resync while a drag is hovering.
        pane.resyncStrip()
        #expect(strip.dropPlaceholderIndex == before)
        #expect(strip.dropHitTest(screenPoint: point, payload: .tab(id: "incoming", sourceStripID: UUID())) == proposal)
        strip.dropEnded(committed: nil)
        #expect(strip.dropPlaceholderIndex == nil)
    }
}
