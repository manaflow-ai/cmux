import AppKit
import CmuxNextActions
import CmuxNextCompat
import CmuxNextDaemon

/// A pane's "…" at its tab bar's trailing end (Leo 2026-10-12; was cx-kk7lm's row of buttons):
/// it shows while the pointer is over the pane's top-right corner. Its menu is the strip plus's
/// (a terminal, a browser, an agent chat, … in this pane), then Split Right, Split Down, the shown
/// tab's own actions and Toggle Pane Zoom. A chat's pane has none: its header has its own (acpmux
/// header/ChatHeaderTools.tsx).
@MainActor
final class PaneToolbar {
    /// What the selected tab is, for its own actions; nil is a chat: no "…".
    enum Kind: Equatable, Sendable {
        case newTab, terminal, browser, other
    }

    /// What the bar follows: the selected tab, its kind and whether the pane is zoomed.
    struct State: Equatable, Sendable {
        var target: String?
        var kind: Kind?
        var zoomed = false
    }

    let view = PaneToolbarView()
    private let registry: () -> ActionRegistry?
    /// The strip plus's menu for this pane (what opens in it).
    private let newTabMenu: () -> NSMenu?
    private(set) var target: String?
    private(set) var kind: Kind?
    private(set) var zoomed = false
    private var observation: Task<Void, Never>?

    init(registry: @escaping () -> ActionRegistry?, newTabMenu: @escaping () -> NSMenu?) {
        self.registry = registry
        self.newTabMenu = newTabMenu
        view.moreMenu = { [weak self] in self?.moreMenu() }
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated { observation?.cancel() }
    }

    /// The pane's "…": follows its selected tab and the pane's zoom.
    convenience init(pane: PaneController) {
        let services = pane.services
        self.init(registry: { [weak services] in services?.registry },
                  newTabMenu: { [weak pane] in
                      // The plus's rows, without its Chromium warmup: "…" is opened for a split as often.
                      pane.map { $0.services.registry.makeContextMenu(for: .newTab, target: ActionTargetRef(kind: .pane, id: $0.paneKey)) }
                  })
        // task-owner: lives as long as the pane's view; event-driven (Observation)
        observation = Task { [weak self, weak pane] in
            for await state in ObservationStream({ [weak pane] in pane.map(Self.state) }) {
                guard let self, let state else { return }
                update(target: state.target, kind: state.kind, zoomed: state.zoomed)
            }
        }
    }

    private static func state(_ pane: PaneController) -> State {
        guard let key = pane.stripModel.selectedID?.rawValue, let tab = pane.pane.tabs.first(where: { $0.id == key }) else {
            return State()
        }
        // The pane's own workspace, not a store scan: this runs for every pane.
        let zoomed = pane.workspace?.workspace.screens.contains { $0.zoomedPane == pane.pane.handle } ?? false
        return State(target: key, kind: kind(tab, isNewTabPage: TabTitleResolver(services: pane.services).isNewTabPage(tab)), zoomed: zoomed)
    }

    static func kind(_ tab: TabModel, isNewTabPage: Bool) -> Kind? {
        if tab.agentSession != nil { return isNewTabPage ? .newTab : nil }
        if tab.page != nil { return .other }
        switch tab.kind {
        case .pty, .remoteTerminal: return .terminal
        case .browser: return .browser
        case .conversation: return nil
        case .other: return .other
        }
    }

    /// The splits, the tab's own actions for `kind`, then the pane's zoom.
    static func actions(_ kind: Kind) -> [ActionID] {
        let own: [ActionID] = switch kind {
        case .newTab: ["openDiffViewer", "file.open", "agentPane.searchChats"]
        case .terminal: ["openDiffViewer", "file.open"]
        case .browser, .other: []
        }
        return ["splitRight", "splitDown"] + own + [zoom]
    }

    static let zoom: ActionID = "toggleSplitZoom"

    /// Shows "…" for tab `target` of `kind` (nil: none); lit while the pane is zoomed.
    func update(target: String?, kind: Kind?, zoomed: Bool = false) {
        self.target = target
        self.kind = kind
        self.zoomed = zoomed
        view.show(more: target != nil && kind != nil, lit: zoomed && target != nil && kind != nil)
    }

    /// The tab's actions "…" offers: those it can run.
    func tabActions() -> [ActionID] {
        guard let registry = registry(), let target, let kind else { return [] }
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: target))
        return Self.actions(kind).filter {
            ActionTargetReasons.canPerform($0, invocation: invocation, in: registry)
                && (kind != .newTab || ($0 != "splitRight" && $0 != "splitDown"))
        }
    }

    /// "…": what opens in the pane, then the splits and the tab's own actions, with their keys.
    private func moreMenu() -> NSMenu? {
        guard let registry = registry(), let target, kind != nil else { return nil }
        let menu = newTabMenu() ?? NSMenu()
        let own = registry.makeContextMenu(for: .tab, target: ActionTargetRef(kind: .tab, id: target), entries: tabActions().map { .action($0) })
        if !menu.items.isEmpty, !own.items.isEmpty { menu.addItem(.separator()) }
        for item in own.items {
            own.removeItem(item)
            menu.addItem(item)
        }
        return menu
    }
}

enum PaneToolbarStrings {
    static var more: String { String(localized: "paneToolbar.more", defaultValue: "More", bundle: .module) }
}
