// A top page (Home, History, Settings, the first-run Bring your history page) fills a window's
// content area over its parked workspace (TOP-SECTION-ITEMS-ARE-PAGES). It has no tabs: a run on
// an existing tab that names none is refused. A person's run of an action that opens content in the
// workspace (`ActionDescriptor.opensWorkspaceContent`) leaves the page first and runs there, as
// Chrome's Cmd-T opens a tab over its welcome page. Before, those runs were refused too, so on a
// fresh profile Ctrl-` over Bring your history made no terminal (P0, STATUS 10364).

/// The App's answers about the active window's top page.
@MainActor
public struct ActionTopPageRules {
    /// Whether the active window shows a top page.
    public var isShowing: @MainActor () -> Bool
    /// Leaves the active window's top page for its workspace, in the same turn.
    public var leave: @MainActor () -> Void
    /// The refusal of a run on an existing tab while a page shows ("This page has no tabs.").
    public var noTabs: @MainActor () -> String

    public init(isShowing: @escaping @MainActor () -> Bool, leave: @escaping @MainActor () -> Void,
                noTabs: @escaping @MainActor () -> String) {
        self.isShowing = isShowing
        self.leave = leave
        self.noTabs = noTabs
    }
}

extension ActionRegistry {
    /// Installs `rules` (after the actions are bound): every action whose only target is a tab and
    /// that opens no content refuses while a page shows and the run names no tab, so menus, the
    /// palette, the keys and the CLI agree.
    public func install(_ rules: ActionTopPageRules) {
        topPageRules = rules
        for descriptor in descriptors where descriptor.targets == [.tab] && !descriptor.opensWorkspaceContent {
            let previous = action(for: descriptor.id)?.targetUnavailableReason
            ActionTargetReasons.set(descriptor.id, in: self) { [weak self] invocation in
                if let reason = previous?(invocation) { return reason }
                guard invocation.target == nil, invocation["tab"] == nil, let rules = self?.topPageRules, rules.isShowing() else { return nil }
                return rules.noTabs()
            }
        }
    }

    /// Before the handler: a person's run of an action that opens content, naming no tab or pane,
    /// leaves the page, so the handler finds the workspace's focused pane and the new content shows
    /// at once. The page is left, not closed. A script's or agent's run never takes the page away.
    func leavesTopPage(for id: ActionID, _ invocation: ActionInvocation, run: ActionRunScope) {
        guard let rules = topPageRules, run.origin == .user, run.allowsViewChange, descriptor(for: id)?.opensWorkspaceContent == true,
              invocation.target == nil, invocation["tab"] == nil, invocation["pane"] == nil, rules.isShowing() else { return }
        rules.leave()
    }
}
