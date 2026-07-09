import AppKit

/// AppKit target/action receiver for the sidebar-provider switcher menu.
///
/// One instance is created per ``CmuxExtensionSidebarSelection/showMenu(anchorView:event:)``
/// invocation and retained for the duration of the modal menu, then released.
/// It holds the resolver that persists the selection, so it replaces the former
/// process-wide `.shared` singleton with a short-lived per-presentation instance
/// carrying an injected dependency, matching the refactor's de-singletonization
/// direction (no static runtime state).
@MainActor
final class CmuxExtensionSidebarMenuTarget: NSObject {
    private let selection: CmuxExtensionSidebarSelection

    /// Creates a target that writes selections through the given resolver.
    init(selection: CmuxExtensionSidebarSelection) {
        self.selection = selection
    }

    /// Persists the provider id carried by the selected menu item.
    @objc func selectProvider(_ sender: NSMenuItem) {
        guard let providerId = sender.representedObject as? String else { return }
        selection.setProviderId(providerId)
    }
}
