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

    func applyWorkspaceBonsplitConfiguration(_ workspaceConfiguration: BonsplitConfiguration) {
        let previousAppearance = bonsplitController.configuration.appearance
        let nextConfiguration = workspaceConfiguration.remoteTmuxEmbedded
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
