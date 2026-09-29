import CoreGraphics

/// Per-window tab bar insets that make room for window chrome drawn over the
/// workspace tab bars (traffic lights, the persistent right-sidebar button).
extension TabManager {
    func applyCreationChromeInheritance(
        to newWorkspace: Workspace,
        from sourceWorkspace: Workspace?
    ) {
        // The persistent right-sidebar button reserves trailing tab bar space
        // per window; new workspaces inherit it like the leading inset below.
        if let inheritedTrailingInset = currentWindowTabBarTrailingInset {
            applyTabBarTrailingInset(inheritedTrailingInset, to: newWorkspace)
        }
        // Sidebar-toggle relayout updates the live Bonsplit leading inset so minimal-mode
        // workspaces reserve traffic-light space. New workspaces need that same inset
        // copied immediately because creation itself does not trigger the resync path.
        let inheritedLeadingInset = currentWindowTabBarLeadingInset
            ?? sourceWorkspace?.bonsplitController.configuration.appearance.tabBarLeadingInset
        guard let inheritedLeadingInset else { return }
        applyTabBarLeadingInset(inheritedLeadingInset, to: newWorkspace)
    }

    /// Reserves `inset` points at the trailing end of each workspace's
    /// top-right pane tab bar, for the persistent right-sidebar button.
    func syncWorkspaceTabBarTrailingInset(_ inset: CGFloat) {
        let normalizedInset = max(0, inset)
        currentWindowTabBarTrailingInset = normalizedInset
        for tab in tabs {
            applyTabBarTrailingInset(normalizedInset, to: tab)
        }
    }

    func applyTabBarTrailingInset(_ inset: CGFloat, to workspace: Workspace) {
        if workspace.bonsplitController.configuration.appearance.tabBarTrailingInset != inset {
            workspace.bonsplitController.configuration.appearance.tabBarTrailingInset = inset
        }
    }

    func syncWorkspaceTabBarLeadingInset(_ inset: CGFloat) {
        let normalizedInset = max(0, inset)
        currentWindowTabBarLeadingInset = normalizedInset
        for tab in tabs {
            applyTabBarLeadingInset(normalizedInset, to: tab)
        }
    }

    func applyTabBarLeadingInset(_ inset: CGFloat, to workspace: Workspace) {
        if workspace.bonsplitController.configuration.appearance.tabBarLeadingInset != inset {
            workspace.bonsplitController.configuration.appearance.tabBarLeadingInset = inset
        }
    }
}
