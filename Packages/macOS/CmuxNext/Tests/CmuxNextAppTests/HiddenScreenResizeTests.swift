import AppKit
@testable import CmuxNextLayout
import Testing

/// A workspace's hidden screens lay out when they show, not on every
/// live-resize tick of the window: each tick re-ran every hidden screen's
/// full geometry and pane reconcile (QA spree 2026-10-21). Shown again, a
/// screen has the window's size at once.
@MainActor struct HiddenScreenResizeTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    @Test func aHiddenScreenLaysOutWhenItShows() throws {
        _ = NSApplication.shared
        let provider = Panes()
        let screens = [
            LayoutScreen(id: "s1", name: "one", layout: .columns([LayoutColumn(id: "c1", width: 1, root: .leaf("p1"))])),
            LayoutScreen(id: "s2", name: "two", layout: .columns([LayoutColumn(id: "c2", width: 1,
                root: .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p2"), b: .leaf("p3")))])),
        ]
        let model = LayoutModel(screens: screens, activeScreenID: "s1", focusedPane: "p1")
        let root = LayoutRootView(model: model, contentProvider: provider)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        let hidden = try #require(root.screenViews["s2"])
        try #require(hidden.isHidden)
        let before = hidden.geometry.panes

        window.setContentSize(NSSize(width: 1400, height: 700))
        root.layoutSubtreeIfNeeded()
        #expect(hidden.needsReconcileOnShow, "the hidden screen laid out on the resize")
        #expect(hidden.geometry.panes == before)

        model.selectScreen("s2")
        root.syncWithModel()
        root.layoutSubtreeIfNeeded()
        try #require(!hidden.isHidden)
        #expect(!hidden.needsReconcileOnShow)
        let right = try #require(hidden.geometry.panes["p3"])
        #expect(right.maxX > 1000, "shown, the screen fills the wider window: \(hidden.geometry.panes)")
    }
}
