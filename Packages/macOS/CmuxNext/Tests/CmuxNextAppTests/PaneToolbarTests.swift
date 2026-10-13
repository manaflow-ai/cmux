import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import Testing

/// A pane's top-right corner (Leo 2026-10-12): one "…", shown on hover, in place of the row of
/// buttons. Its menu opens a tab in the pane (the strip plus's menu), then splits the pane and runs
/// the shown tab's own actions. A zoomed pane keeps "…" shown and lit.
@MainActor
struct PaneToolbarTests {
    final class Bar {
        let registry = ActionRegistry.standard()
        private(set) var runs: [(id: String, invocation: ActionInvocation)] = []
        lazy var toolbar = PaneToolbar(registry: { [registry] in registry }, newTabMenu: { Bar.newTabMenu() })

        init() {
            for id in ["splitRight", "splitDown", "openDiffViewer", "file.open", "agentPane.searchChats", "toggleSplitZoom"] {
                registry.register(Action(id: ActionID(rawValue: id), title: id, invoke: { [unowned self] invocation in
                    runs.append((id, invocation))
                }, handler: {}))
            }
        }

        /// What the strip's plus offers for the pane.
        static func newTabMenu() -> NSMenu {
            let menu = NSMenu()
            ["New Terminal Tab", "New Browser Tab", "New Agent Chat"].forEach { menu.addItem(withTitle: $0, action: nil, keyEquivalent: "") }
            return menu
        }

        var view: PaneToolbarView { toolbar.view }
        /// The controls the corner can show, by accessibility label.
        var controls: [String] {
            view.subviews.compactMap { $0 as? TitlebarBandButton }.filter { !$0.isHidden }.map { $0.accessibilityLabel() ?? "" }
        }
        /// The "…" menu's rows; "-" is a separator.
        var more: [String] {
            (view.moreMenu?()?.items ?? []).map { $0.isSeparatorItem ? "-" : $0.title }
        }

        func choose(_ title: String) {
            guard let menu = view.moreMenu?(), menu.indexOfItem(withTitle: title) >= 0 else {
                Issue.record("no \(title)")
                return
            }
            menu.performActionForItem(at: menu.indexOfItem(withTitle: title))
        }
    }

    @Test func aTerminalPaneHasOnlyMoreWithWhatOpensThenSplitsAndItsActions() {
        let bar = Bar()
        bar.toolbar.update(target: "surface:7", kind: .terminal, hidden: [])
        #expect(bar.controls == ["More"])
        #expect(bar.more == ["New Terminal Tab", "New Browser Tab", "New Agent Chat", "-", "Split Right", "Split Down", "Open Diff Viewer", "Open File…", "Toggle Pane Zoom"])

        bar.choose("Split Down")
        #expect(bar.runs.map(\.id) == ["splitDown"])
        #expect(bar.runs.last?.invocation.target == ActionTargetRef(kind: .tab, id: "surface:7"))
    }

    @Test func eachPaneKindOffersItsOwnActionsAndAChatHasNoMore() {
        let bar = Bar()
        bar.toolbar.update(target: "surface:1", kind: .newTab, hidden: [])
        #expect(bar.controls == ["More"])
        #expect(bar.more == ["New Terminal Tab", "New Browser Tab", "New Agent Chat", "-", "Split Right", "Split Down", "Open Diff Viewer", "Open File…",
                             "Search Agent Chats", "Toggle Pane Zoom"])
        bar.toolbar.update(target: "surface:2", kind: .browser, hidden: [])
        #expect(bar.controls == ["More"])
        #expect(bar.more == ["New Terminal Tab", "New Browser Tab", "New Agent Chat", "-", "Split Right", "Split Down", "Toggle Pane Zoom"])
        bar.toolbar.update(target: "surface:3", kind: nil, hidden: [])
        #expect(bar.controls.isEmpty)
        #expect(bar.view.intrinsicContentSize.width == 0)
    }

    /// "…" waits for the pointer in the pane's corner; a zoomed pane shows it lit without hover.
    @Test func moreShowsOnHoverAndStaysLitWhileZoomed() {
        let bar = Bar()
        bar.toolbar.update(target: "surface:7", kind: .terminal, hidden: [])
        #expect(!bar.view.reveal.isRevealed)
        bar.view.reveal.setPointerInside(true)
        #expect(bar.view.reveal.isRevealed)
        bar.view.reveal.setPointerInside(false)

        bar.toolbar.update(target: "surface:7", kind: .terminal, hidden: [], zoomed: true)
        #expect(bar.view.reveal.isRevealed)
        #expect(bar.view.moreButton.state == .on)
        #expect(bar.controls == ["More"])
        bar.toolbar.update(target: "surface:7", kind: .terminal, hidden: [], zoomed: false)
        #expect(!bar.view.reveal.isRevealed)
        #expect(bar.view.moreButton.state == .off)
    }

    /// An action in `tabs.hiddenButtons` stays out of "…".
    @Test func aHiddenActionIsLeftOutOfMore() {
        let bar = Bar()
        bar.toolbar.update(target: "surface:7", kind: .terminal, hidden: ["openDiffViewer"])
        #expect(bar.more == ["New Terminal Tab", "New Browser Tab", "New Agent Chat", "-", "Split Right", "Split Down", "Open File…", "Toggle Pane Zoom"])
    }

    /// "…" opens its menu on press, like a pop-up button (POLISH: press-drag-release): press, drag
    /// to a row, release to run it; a plain click leaves it open.
    @Test func moreOpensItsMenuOnPress() throws {
        let bar = Bar()
        bar.toolbar.update(target: "surface:2", kind: .browser, hidden: [])
        var presented: [[String]] = []
        bar.view.moreButton.presentMenu = { menu, _ in presented.append(menu.items.map { $0.isSeparatorItem ? "-" : $0.title }) }
        let press = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        bar.view.moreButton.mouseDown(with: press)
        #expect(presented == [["New Terminal Tab", "New Browser Tab", "New Agent Chat", "-", "Split Right", "Split Down", "Toggle Pane Zoom"]])
    }
}
