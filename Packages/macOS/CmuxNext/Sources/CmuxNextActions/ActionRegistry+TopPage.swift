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
    /// Whether leaving the active window's top page shows a workspace (classic Home stands for the
    /// hidden home workspace: leaving shows the Home page again).
    public var canLeave: @MainActor () -> Bool
    /// Leaves the active window's top page for its workspace, in the same turn.
    public var leave: @MainActor () -> Void
    /// The refusal of a run on an existing tab while a page shows ("This page has no tabs.").
    public var noTabs: @MainActor () -> String
    /// The refusal of a new tab or pane while a page shows ("This page has no panes.").
    public var noPanes: @MainActor () -> String

    public init(isShowing: @escaping @MainActor () -> Bool, canLeave: @escaping @MainActor () -> Bool, leave: @escaping @MainActor () -> Void,
                noTabs: @escaping @MainActor () -> String, noPanes: @escaping @MainActor () -> String) {
        self.isShowing = isShowing
        self.canLeave = canLeave
        self.leave = leave
        self.noTabs = noTabs
        self.noPanes = noPanes
    }
}

extension ActionRegistry {
    /// Installs `rules` (after the actions are bound), so menus, the palette, the keys and the CLI
    /// agree: while a page shows and the run names no tab, every action whose only target is a tab
    /// and that opens no content refuses ("no tabs"), and so does an action that opens content
    /// ("no panes") when automation runs it (a script, an agent, the CLI, another client:
    /// automation never changes what the person sees) or when leaving the page would show no
    /// workspace (classic Home): refused before any window change.
    public func install(_ rules: ActionTopPageRules) {
        topPageRules = rules
        for descriptor in descriptors where descriptor.opensWorkspaceContent || descriptor.targets == [.tab] {
            let opens = descriptor.opensWorkspaceContent
            let previous = action(for: descriptor.id)?.targetUnavailableReason
            ActionTargetReasons.set(descriptor.id, in: self) { [weak self] invocation in
                if let reason = previous?(invocation) { return reason }
                guard Self.namesNoObject(invocation), let rules = self?.topPageRules, rules.isShowing() else { return nil }
                guard opens else { return rules.noTabs() }
                return Self.isPersonsRun(invocation) && rules.canLeave() ? nil : rules.noPanes()
            }
        }
    }

    /// In the run's timing, just before the handler: a person's run of an action that opens
    /// content, naming no tab or pane, leaves the page, so the handler finds the workspace's focused
    /// pane and the new content shows at once. The page is left, not closed. False (refused): a
    /// page still shows (the target reason refuses a leave that would show no workspace first).
    func leavesTopPage(for id: ActionID, _ invocation: ActionInvocation) -> Bool {
        guard let rules = topPageRules, descriptor(for: canonicalID(for: id))?.opensWorkspaceContent == true,
              Self.namesNoObject(invocation), Self.isPersonsRun(invocation), rules.isShowing() else { return true }
        rules.leave()
        guard rules.isShowing() else { return true }
        refuse(rules.noPanes())
        return false
    }

    /// The run names no tab and no pane: it acts on "the focused one".
    private static func namesNoObject(_ invocation: ActionInvocation) -> Bool {
        invocation.target == nil && invocation["tab"] == nil && invocation["pane"] == nil
    }

    /// The run is the person's and may change the view: its effective origin is `user` (an
    /// invocation nested in a CLI run is the CLI's) and the scope it runs in allows view changes.
    private static func isPersonsRun(_ invocation: ActionInvocation) -> Bool {
        let run = ActionRunScope(invocation, focuses: false).nested(in: ActionRunScope.current)
        return run.origin == .user && run.allowsViewChange
    }
}
