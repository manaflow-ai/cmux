public import CmuxNextActions
public import CmuxNextBridge
public import CmuxNextDaemon
public import CmuxNextLayout

/// What Insert New opens at a divider (`divider.insertNew`'s `kind`).
public enum DividerInsertKind: String, Sendable {
    case terminal, browser, agentChat, newTabPage

    /// What the daemon must serve for this kind's split to carry the insertion's `around` and sizing: without it the
    /// kind's fallback (a plain split, or a tab moved to a split) splits only the target pane (review of #37733).
    var splitCapabilities: [DaemonCapability] {
        switch self {
        case .terminal: [.terminalPlacementEnv]
        case .browser: [.frontendBrowserTabSplit, .splitClientKeys]
        case .agentChat, .newTabPage: [.conversationTabSplit]
        }
    }
}

/// A window's workspace as the divider actions act on it (the app's workspace content).
@MainActor
public protocol DividerWorkspace: AnyObject {
    var layoutModel: LayoutModel { get }
    var handles: LayoutHandleMap { get }
    var daemon: DaemonService { get }
    /// The focused pane: without a `split`, the actions act on the divider beside it.
    var dividerFocusedPane: LayoutPaneID? { get }
    /// Opens `kind` in a new pane split from `pane`, right of it (`horizontal`) or below it, through the same path
    /// as Split Right or Split Down, with `insertion`'s `around` and sizing. Returns why it cannot, or nil.
    func openAtDivider(_ kind: DividerInsertKind, from pane: LayoutPaneID, horizontal: Bool, insertion: DividerInsertion,
                       origin: ActionOrigin) -> String?
}

/// The app's windows, for the divider actions.
@MainActor
public protocol DividerActionHost: AnyObject {
    /// The workspace `invocation` names (its workspace target, else the active window's), as a window shows it; nil
    /// when no window shows it (the lookup said why).
    func dividerWorkspace(_ invocation: ActionInvocation) -> (any DividerWorkspace)?
}

/// A split's divider (its right-click menu, `DividerActionCatalog` in cmux-action-catalog): Insert New opens a pane at
/// the divider, between the two sides it separates (``DividerInsertPlan``), with the divider's sizing shown in the
/// same layout as the new pane; Hide Divider and Show Divider set the split's line in the daemon's layout
/// (`set-divider-visible`), shown in this turn through a store intent.
@MainActor
public struct DividerActions {
    let host: any DividerActionHost

    /// - Parameter host: The app's windows (`AppServices`).
    public init(host: any DividerActionHost) { self.host = host }

    /// Binds Insert New, Hide Divider and Show Divider into `registry`.
    public func bind(into registry: ActionRegistry) {
        let host = host
        registry.bindEffect("divider.insertNew") { invocation in Self.insert(invocation, host) }
        registry.bindEffect("divider.hide") { invocation in Self.setVisible(false, invocation, host) }
        registry.bindEffect("divider.show") { invocation in Self.setVisible(true, invocation, host) }
        // The menu offers the one that changes something: Hide on a drawn divider, Show on a hidden one.
        ActionTargetVisibility.hide("divider.hide", in: registry) { [weak registry] invocation in
            registry?.withoutRefusals { Self.divider(invocation, host) }.map { $0.0.layoutModel.dividerHidden($0.1) } ?? false
        }
        ActionTargetVisibility.hide("divider.show", in: registry) { [weak registry] invocation in
            registry?.withoutRefusals { Self.divider(invocation, host) }.map { !$0.0.layoutModel.dividerHidden($0.1) } ?? true
        }
    }

    /// The workspace and the divider's split (layout id) `invocation` names: its `split` argument (the layout's id,
    /// the daemon's public id or its handle), else the divider beside the focused pane.
    static func divider(_ invocation: ActionInvocation, _ host: any DividerActionHost) -> (any DividerWorkspace, LayoutSplitID)? {
        guard let workspace = host.dividerWorkspace(invocation) else { return nil }
        let splits = workspace.handles.splits
        guard let name = invocation["split"]?.stringValue?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            return workspace.dividerFocusedPane.flatMap(workspace.layoutModel.divider(beside:)).map { (workspace, $0) }
        }
        let split = [LayoutSplitID(name), LayoutSplitID("split:\(name)")].first { splits[$0] != nil }
            ?? splits.first { "\($0.value.rawValue)" == name }?.key
        return split.map { (workspace, $0) }
    }

    static func insert(_ invocation: ActionInvocation, _ host: any DividerActionHost) -> ActionEffect {
        guard let (workspace, split) = divider(invocation, host), let plan = workspace.layoutModel.dividerInsertPlan(at: split)
        else { return .refused(RefusalStrings.noDivider) }
        let daemon = workspace.daemon
        let kind = invocation["kind"]?.stringValue.flatMap(DividerInsertKind.init(rawValue:)) ?? .terminal
        if let missing = ([.splitAround] + kind.splitCapabilities).first(where: { !daemon.supports($0.rawValue) }) {
            return .refused(daemon.missingCapabilityMessage(missing.rawValue))
        }
        // A first side that is a split the daemon has not named yet (one still opening) cannot be wrapped.
        let around = plan.around.map { workspace.handles.splits[$0] }
        if case .some(.none) = around { return .refused(RefusalStrings.noDivider) }
        let insertion = DividerInsertion(around: around ?? nil, sizing: plan.sizing)
        let refusal = workspace.openAtDivider(kind, from: plan.target, horizontal: plan.axis == .horizontal,
                                              insertion: insertion, origin: invocation.origin)
        return refusal.map { .refused($0) } ?? .done
    }

    static func setVisible(_ visible: Bool, _ invocation: ActionInvocation, _ host: any DividerActionHost) -> ActionEffect {
        guard let (workspace, split) = divider(invocation, host), let handle = workspace.handles.splits[split],
              let screen = workspace.layoutModel.screens.first(where: { $0.layout.tree(containing: split) != nil }),
              let screenHandle = workspace.handles.screens[screen.id]
        else { return .refused(RefusalStrings.noDivider) }
        let daemon = workspace.daemon, capability = DaemonCapability.splitDividerVisibility.rawValue
        guard daemon.supports(capability) else { return .refused(daemon.missingCapabilityMessage(capability)) }
        return daemon.intentEffect("set-divider-visible", .setDividerVisible(screen: screenHandle, split: handle, visible: visible)) {
            try await $0.setDividerVisible(handle, visible: visible)
        }
    }
}
