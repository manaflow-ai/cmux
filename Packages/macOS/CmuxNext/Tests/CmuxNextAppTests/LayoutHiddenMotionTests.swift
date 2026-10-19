import AppKit
@testable import CmuxNextLayout
import CmuxNextDesign
import Testing

/// Lucas 2026-10-19: a workspace showed nothing, its pane parked one width off the left edge. Its
/// columns had collapsed to one pane as it was hidden; the pane's spring started from where it
/// showed, the hidden workspace's clock stopped, and showing it again never restarted it. Hiding
/// a layout now ends its motion where it was going.
@MainActor
struct LayoutHiddenMotionTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    @Test func hidingTheLayoutEndsItsMotion() {
        let split: SplitNode = .split("h", axis: .horizontal, ratio: 0.5, a: .leaf("p2"), b: .leaf("p1"))
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(split))], activeScreenID: "s",
                                focusedPane: "p1")
        let root = LayoutRootView(model: model, contentProvider: Panes())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        // The test is the clock: the display link never ticks.
        root.driver.isManual = true

        // p2 closes: p1 springs from the right half over the whole screen.
        model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(.leaf("p1")))])
        root.syncWithModel()
        let screen = root.screenViews["s"]
        #expect(screen?.hasMotion == true)

        root.isHidden = true
        #expect(screen?.hasMotion == false)
        let frame = screen?.paneFrames["p1"]
        #expect(frame != nil && frame?.rect == frame?.targetRect)
    }
}
