public import AppKit
public import CmuxNextActions

extension MacScreenPages {
    /// Screen tabs and the sharing indicator use the same registered actions and keyboard bindings. SECURITY:
    /// `isPersonEvent`, the app's strict check of the person's own input, is the one the device-control prompt's
    /// Allows answer by (``MacScreenApprovalPrompt/isPersonEvent``); with none, no click allows.
    public func useActions(of registry: ActionRegistry, isPersonEvent: @escaping @MainActor (NSEvent) -> Bool = { _ in false }) {
        approval.isPersonEvent = isPersonEvent
        useShortcuts(of: registry)
        hubHost.indicatorMenuItem = { [weak registry] in registry?.makeMenuItem(for: $0) }
        shareThisMac = { [weak registry] in registry?.perform("macScreen.shareThisMac") }
    }
}
