public import CmuxNextActions

extension MacScreenPages {
    /// Screen tabs and the sharing indicator use the same registered actions and keyboard bindings.
    public func useActions(of registry: ActionRegistry) {
        useShortcuts(of: registry)
        hubHost.indicatorMenuItem = { [weak registry] in registry?.makeMenuItem(for: $0) }
    }
}
