public import Foundation

/// Decides whether dismissing the command palette should restore focus to a
/// browser panel's address bar: only when the focused panel is a browser and
/// the panel that held address-bar focus is exactly the focused panel.
public struct CommandPaletteBrowserAddressBarRestorePolicy: Sendable {
    /// Whether the focused panel is a browser panel.
    public let focusedPanelIsBrowser: Bool
    /// The panel that held browser address-bar focus, if any.
    public let focusedBrowserAddressBarPanelId: UUID?
    /// The currently focused panel, if any.
    public let focusedPanelId: UUID?

    /// Captures the browser address-bar restore inputs to evaluate.
    public init(
        focusedPanelIsBrowser: Bool,
        focusedBrowserAddressBarPanelId: UUID?,
        focusedPanelId: UUID?
    ) {
        self.focusedPanelIsBrowser = focusedPanelIsBrowser
        self.focusedBrowserAddressBarPanelId = focusedBrowserAddressBarPanelId
        self.focusedPanelId = focusedPanelId
    }

    /// Whether the address bar should be re-focused after dismiss.
    public var shouldRestore: Bool {
        focusedPanelIsBrowser && focusedBrowserAddressBarPanelId == focusedPanelId
    }
}
