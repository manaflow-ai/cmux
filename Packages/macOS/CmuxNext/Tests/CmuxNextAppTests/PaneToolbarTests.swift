import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import Testing

/// A pane's buttons at its tab bar's trailing end (cx-kk7lm): Split Right, Split Down and the tab's
/// own actions as symbols, four at most, the rest under "…"; a click runs the action on the pane's
/// tab; Hide moves a button into "…" and writes `tabs.hiddenButtons`, the bar's Show brings it back.
@MainActor
struct PaneToolbarTests {
    final class Bar {
        let registry = ActionRegistry.standard()
        private(set) var runs: [(id: String, invocation: ActionInvocation)] = []
        private(set) var written: [Set<String>] = []
        lazy var toolbar = PaneToolbar(registry: { [registry] in registry }, writeHidden: { [unowned self] in written.append($0) })

        init() {
            for id in ["splitRight", "splitDown", "openDiffViewer", "file.open", "agentPane.searchChats", "toggleSplitZoom"] {
                registry.register(Action(id: ActionID(rawValue: id), title: id, invoke: { [unowned self] invocation in
                    runs.append((id, invocation))
                }, handler: {}))
            }
        }

        var view: PaneToolbarView { toolbar.view }
        var buttons: [String] { view.shown.map(\.id.rawValue) }
        /// The "…" menu's rows.
        var more: [String] { view.moreButton.isHidden ? [] : (view.moreMenu?()?.items ?? []).map(\.title) }

        func click(_ id: String) {
            guard let index = view.shown.firstIndex(where: { $0.id.rawValue == id }) else {
                Issue.record("no \(id) button")
                return
            }
            view.buttons[index].performClick(nil)
        }

        func choose(_ menu: NSMenu?, _ title: String) {
            guard let menu, menu.indexOfItem(withTitle: title) >= 0 else {
                Issue.record("no \(title)")
                return
            }
            menu.performActionForItem(at: menu.indexOfItem(withTitle: title))
        }
    }

    @Test func aTerminalPaneShowsItsSplitsAndActionsAndRunsThemOnItsTab() {
        let bar = Bar()
        bar.toolbar.update(target: "surface:7", kind: .terminal, hidden: [])
        #expect(bar.buttons == ["splitRight", "splitDown", "openDiffViewer", "file.open"])
        #expect(bar.more == ["Toggle Pane Zoom"])
        #expect(bar.view.buttons.map(\.themedToolTip) == ["Split Right", "Split Down", "Open Diff Viewer", "Open File"])
        #expect(bar.view.buttons.first?.themedToolTipShortcut == bar.registry.shortcutDisplay(for: "splitRight"))

        bar.click("splitDown")
        #expect(bar.runs.map(\.id) == ["splitDown"])
        #expect(bar.runs.last?.invocation.target == ActionTargetRef(kind: .tab, id: "surface:7"))
    }

    @Test func eachPaneKindHasItsOwnActionsAndAChatHasNone() {
        let bar = Bar()
        bar.toolbar.update(target: "surface:1", kind: .newTab, hidden: [])
        #expect(bar.buttons == ["splitRight", "splitDown", "openDiffViewer", "file.open"])
        #expect(bar.more == ["Search Agent Chats", "Toggle Pane Zoom"])
        bar.toolbar.update(target: "surface:2", kind: .browser, hidden: [])
        #expect(bar.buttons == ["splitRight", "splitDown", "toggleSplitZoom"])
        #expect(bar.more.isEmpty)
        bar.toolbar.update(target: "surface:3", kind: nil, hidden: [])
        #expect(bar.buttons.isEmpty && bar.more.isEmpty)
        #expect(bar.view.intrinsicContentSize.width == 0)
    }

    @Test func hideMovesAButtonIntoMoreAndShowBringsItBack() throws {
        let bar = Bar()
        bar.toolbar.update(target: "surface:7", kind: .terminal, hidden: [])
        let splitDown = try #require(bar.view.shown.first { $0.id == "splitDown" })
        bar.choose(bar.view.hideMenu(splitDown), "Hide Split Down Button")
        #expect(bar.written == [["splitDown"]])
        #expect(bar.buttons == ["splitRight", "openDiffViewer", "file.open", "toggleSplitZoom"])
        #expect(bar.more == ["Split Down"])

        // The setting comes back from the file: the bar stays as it is.
        bar.toolbar.update(target: "surface:7", kind: .terminal, hidden: ["splitDown"])
        #expect(bar.buttons == ["splitRight", "openDiffViewer", "file.open", "toggleSplitZoom"])

        bar.choose(bar.view.showMenu(), "Show Split Down Button")
        #expect(bar.written == [["splitDown"], []])
        #expect(bar.buttons == ["splitRight", "splitDown", "openDiffViewer", "file.open"])
        #expect(bar.view.showMenu() == nil)
    }
}
