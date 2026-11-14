import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextTabs
import Testing

/// The tab bar's trailing end has no buttons of its own (user 2026-11-13: "get rid of these buttons", on the
/// Toggle Terminal and Chat pair and the pane's "…"): no "…", no terminal and chat toggle, so with nothing
/// pinned (`tabs.toolbarButtons`, empty by default) the bar takes no width and the tabs keep the whole row.
@MainActor @Suite(.serialized)
struct PaneTabBarNoTrailingButtonsTests {
    static func toolbar() -> PaneToolbar {
        _ = NSApplication.shared
        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        let toolbar = PaneToolbar(registry: { registry }, newTabMenu: {
            registry.makeContextMenu(for: .newTab, target: ActionTargetRef(kind: .pane, id: "p1"))
        })
        toolbar.view.frame = NSRect(x: 0, y: 0, width: 400, height: 32)
        return toolbar
    }

    /// Any control the bar shows a person: not what is merely built hidden, and not the hover reveal's pointer
    /// probe (a private view that draws nothing; it only tells the reveal where the pointer is).
    static func shownControls(_ view: NSView) -> [NSView] {
        view.layoutSubtreeIfNeeded()
        return view.subviews.filter { !$0.isHidden && !String(describing: type(of: $0)).hasSuffix("HoverRevealProbe") }
    }

    @Test(arguments: [PaneToolbar.Kind.terminal, .newTab, .browser, .other])
    func noControlsAndNoWidthWithNothingPinned(kind: PaneToolbar.Kind) {
        let toolbar = Self.toolbar()
        toolbar.update(target: "t1", kind: kind, paneKinds: [kind])
        #expect(Self.shownControls(toolbar.view).isEmpty)
        #expect(toolbar.view.intrinsicContentSize.width == 0)
        #expect(toolbar.view.tabRowWidth == PaneToolbarView.trailingGap)
    }

    @Test func noOverflowButtonOrTerminalChatToggleIsBuilt() {
        let toolbar = Self.toolbar()
        toolbar.update(target: "t1", kind: .terminal, paneKinds: [.terminal])
        let kinds = toolbar.view.subviews.map { String(describing: type(of: $0)) }
        #expect(!kinds.contains("OverflowButton"))
        #expect(!kinds.contains("PaneTerminalChatToggleView"))
    }

    // A zoomed pane still shows its one Exit Zoom button, alone in the trailing slot.
    @Test func aZoomedPaneShowsOnlyExitZoom() {
        let toolbar = Self.toolbar()
        toolbar.update(target: "t1", kind: .terminal, zoomed: true, paneKinds: [.terminal])
        let shown = Self.shownControls(toolbar.view)
        #expect(shown.count == 1)
        #expect(shown.first === toolbar.view.zoomButton)
    }
}
