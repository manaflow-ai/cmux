/// An extension management operation, independent of who asks for it.
///
/// ``BrowserExtensionAutomationPolicy`` decides what an automation caller
/// (CLI or socket) may do with each one.
public enum BrowserExtensionOperation: String, Sendable, CaseIterable {
    /// List extensions and shortcuts.
    case list
    /// Load an unpacked extension folder.
    case loadUnpacked = "load-unpacked"
    /// Install a packed `.crx` file.
    case installPacked = "install-crx"
    /// Enable an extension.
    case enable
    /// Disable an extension.
    case disable
    /// Remove an extension.
    case remove
    /// Reload an extension.
    case reload
    /// Pin an extension's toolbar action.
    case pin
    /// Unpin an extension's toolbar action.
    case unpin
    /// Reorder a pinned action.
    case move
    /// Open the options page.
    case options
    /// Click the toolbar action (grants `activeTab` on the page).
    case run
    /// Run a keyboard command (grants `activeTab` on the page).
    case command
    /// Open the Chrome Web Store or the extensions page in a tab.
    case openPage = "open-page"
}
