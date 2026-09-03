import Bonsplit
import Observation

@MainActor
extension RemoteTmuxWindowMirror {
    func observeWorkspaceBonsplitConfiguration() {
        guard let source = workspaceBonsplitController else { return }
        let configuration = withObservationTracking {
            source.configuration
        } onChange: { [weak self, weak source] in
            Task { @MainActor [weak self, weak source] in
                guard let self, self.workspaceBonsplitController === source else { return }
                self.observeWorkspaceBonsplitConfiguration()
            }
        }
        applyWorkspaceBonsplitConfiguration(configuration)
    }

    /// Whether a mirrored window shows its per-pane tab bars.
    ///
    /// A mirror pane is one tmux pane, which is one surface, so its tab bar can never hold a
    /// second tab to switch to. In a single-pane window it therefore repeats the workspace
    /// tab's own title directly beneath it and carries nothing else, which reads as a doubled
    /// tab bar. Split the window and the same bars start earning their space: they name each
    /// pane and carry its close and split buttons.
    static func paneTabBarVisibility(paneCount: Int) -> TabBarVisibility {
        paneCount > 1 ? .always : .multipleTabs
    }

    /// Re-derives pane tab bar visibility after the pane set changes.
    ///
    /// Showing or hiding the bar changes how much height is left for terminal content, so a
    /// change here has to re-arm the sizing pass the same way a tab bar height change does —
    /// otherwise the panes keep the row count they were given for the other chrome.
    func updatePaneTabBarVisibilityForPaneCount() {
        let visibility = Self.paneTabBarVisibility(paneCount: paneIDsInOrder.count)
        guard bonsplitController.configuration.tabBarVisibility != visibility else { return }
        bonsplitController.configuration.tabBarVisibility = visibility
        setNeedsSizingPassIgnoringInputs()
    }

    func applyWorkspaceBonsplitConfiguration(_ workspaceConfiguration: BonsplitConfiguration) {
        let previousAppearance = bonsplitController.configuration.appearance
        var nextConfiguration = workspaceConfiguration.remoteTmuxEmbedded
        nextConfiguration.tabBarVisibility = Self.paneTabBarVisibility(paneCount: paneIDsInOrder.count)
        let nextAppearance = nextConfiguration.appearance
        let sizingChanged = previousAppearance.tabBarHeight != nextAppearance.tabBarHeight
            || previousAppearance.dividerThickness != nextAppearance.dividerThickness

        bonsplitController.configuration = nextConfiguration
        bonsplitController.tabShortcutHintsEnabled = false
        if sizingChanged {
            setNeedsSizingPassIgnoringInputs()
        }
    }
}
