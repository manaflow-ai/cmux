import AppKit
import CmuxNextActions
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextSettings

/// A pane's buttons at its tab bar's trailing end (Leo, cx-kk7lm): Split Right, Split Down and
/// the shown tab's own key actions as symbols, about four, and "…" for the rest. Every pane has
/// them but a chat's, whose header has its own (acpmux header/ChatHeaderTools.tsx). A hidden
/// button (`tabs.hiddenButtons`) moves into "…"; the bar's right-click shows it again.
@MainActor
final class PaneToolbar {
    /// What the selected tab is, for its own actions; nil is a chat: no buttons.
    enum Kind: Equatable, Sendable {
        case newTab, terminal, browser, other
    }

    /// What the bar follows: the selected tab, its kind and the hidden buttons.
    struct State: Equatable, Sendable {
        var target: String?
        var kind: Kind?
        var hidden: Set<String>
    }

    /// The buttons a bar shows; the rest go under "…".
    static let visibleCount = 4

    let view = PaneToolbarView()
    private let registry: () -> ActionRegistry?
    private let writeHidden: (Set<String>) -> Void
    private(set) var target: String?
    private(set) var kind: Kind?
    private(set) var hidden: Set<String> = []
    private var observation: Task<Void, Never>?

    init(registry: @escaping () -> ActionRegistry?, writeHidden: @escaping (Set<String>) -> Void) {
        self.registry = registry
        self.writeHidden = writeHidden
        view.onPerform = { [weak self] id in self?.perform(id) }
        view.onSetShown = { [weak self] id, shown in self?.setShown(id, shown) }
        view.moreMenu = { [weak self] in self?.moreMenu() }
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated { observation?.cancel() }
    }

    /// The pane's bar: follows its selected tab and the hidden buttons.
    convenience init(pane: PaneController) {
        let services = pane.services
        self.init(registry: { [weak services] in services?.registry }, writeHidden: { [weak services] hidden in
            let value = CmuxNextSettings.JSONValue.array(hidden.sorted().map(CmuxNextSettings.JSONValue.string))
            Task { try? await services?.settings?.set(value, at: PaneToolbarSetting.hiddenButtonsPath) }
        })
        // task-owner: lives as long as the pane's view; event-driven (Observation)
        observation = Task { [weak self, weak pane] in
            for await state in ObservationStream({ [weak pane] in pane.map(Self.state) }) {
                guard let self, let state else { return }
                update(target: state.target, kind: state.kind, hidden: state.hidden)
            }
        }
    }

    private static func state(_ pane: PaneController) -> State {
        let hidden = pane.services.settings.map { PaneToolbarSetting($0.fileRoot).hidden } ?? []
        guard let key = pane.stripModel.selectedID?.rawValue, let tab = pane.pane.tabs.first(where: { $0.id == key }) else {
            return State(hidden: hidden)
        }
        return State(target: key, kind: kind(tab, isNewTabPage: TabTitleResolver(services: pane.services).isNewTabPage(tab)), hidden: hidden)
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

    /// The bar's actions for `kind`, in order: the splits, the tab's own, then the pane's.
    static func actions(_ kind: Kind) -> [ActionID] {
        let own: [ActionID] = switch kind {
        case .newTab: ["openDiffViewer", "file.open", "agentPane.searchChats"]
        case .terminal: ["openDiffViewer", "file.open"]
        case .browser, .other: []
        }
        return ["splitRight", "splitDown"] + own + ["toggleSplitZoom"]
    }

    /// The first `visibleCount` actions not hidden get buttons; the rest, hidden ones too, go under "…".
    static func arrange(_ ids: [ActionID], hidden: Set<String>) -> (shown: [ActionID], more: [ActionID]) {
        let shown = Array(ids.filter { !hidden.contains($0.rawValue) }.prefix(visibleCount))
        return (shown, ids.filter { !shown.contains($0) })
    }

    /// Symbols the New Tab page's tools used; else the action's own.
    private static let symbols: [ActionID: String] = [
        "openDiffViewer": "plusminus", "file.open": "folder", "agentPane.searchChats": "bubble.left.and.text.bubble.right",
    ]

    /// Shows the bar for tab `target` of `kind` (nil: none) with `hidden` buttons under "…".
    func update(target: String?, kind: Kind?, hidden: Set<String>, zoomed: Bool = false) {
        self.target = target
        self.kind = kind
        self.hidden = hidden
        guard let registry = registry(), let target, let kind else { return view.show([], more: false, hidden: []) }
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: target))
        let ids = Self.actions(kind).filter { ActionTargetReasons.canPerform($0, invocation: invocation, in: registry) }
        let (shown, more) = Self.arrange(ids, hidden: hidden)
        func item(_ id: ActionID) -> PaneToolbarItem? {
            guard let descriptor = registry.descriptor(for: id) else { return nil }
            let title = descriptor.title.hasSuffix("…") ? String(descriptor.title.dropLast()) : descriptor.title
            return PaneToolbarItem(id: id, title: title, symbol: Self.symbols[id] ?? descriptor.symbol,
                                   shortcut: registry.shortcutDisplay(for: id))
        }
        view.show(shown.compactMap(item), more: !more.isEmpty, hidden: ids.filter { hidden.contains($0.rawValue) }.compactMap(item))
    }

    private func perform(_ id: ActionID) {
        guard let target else { return }
        _ = registry()?.perform(id, invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: target), origin: .user))
    }

    /// Hide or Show: the setting changes, and the bar follows it; it rearranges now too.
    private func setShown(_ id: ActionID, _ shown: Bool) {
        var hidden = hidden
        if shown { hidden.remove(id.rawValue) } else { hidden.insert(id.rawValue) }
        writeHidden(hidden)
        update(target: target, kind: kind, hidden: hidden)
    }

    /// "…": the actions without a button, with their keys.
    private func moreMenu() -> NSMenu? {
        guard let registry = registry(), let target, let kind else { return nil }
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: target))
        let ids = Self.actions(kind).filter { ActionTargetReasons.canPerform($0, invocation: invocation, in: registry) }
        let more = Self.arrange(ids, hidden: hidden).more
        return registry.makeContextMenu(for: .tab, target: invocation.target, entries: more.map { .action($0) })
    }
}

enum PaneToolbarStrings {
    static var more: String { String(localized: "paneToolbar.more", defaultValue: "More", bundle: .module) }
    static func hide(_ title: String) -> String {
        String(format: String(localized: "paneToolbar.hide", defaultValue: "Hide %@ Button", bundle: .module), title)
    }
    static func show(_ title: String) -> String {
        String(format: String(localized: "paneToolbar.show", defaultValue: "Show %@ Button", bundle: .module), title)
    }
}
