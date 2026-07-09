public import Foundation

/// Pure decision for whether a terminal surface should apply its window-local
/// background during a theme/background pass.
///
/// This is the terminal-domain home of `GhosttyNSView.shouldApplyWindowBackground`.
/// Theme/background application is window-local: during cross-window workspace
/// switches the global active tab manager can lag behind, so the owning
/// window's selected workspace is preferred when available. The view resolves
/// the live tab-manager identities and passes them in as plain values.
public struct TerminalWindowBackgroundPolicy: Sendable {
    /// Creates a stateless terminal window background policy.
    public init() {}

    /// Whether the surface owning `surfaceTabId` should apply its background.
    ///
    /// A surface with no tab id always applies. When the surface has an owning
    /// tab manager, only the owner's currently-selected tab applies; otherwise
    /// the active manager's selection decides, defaulting to apply when neither
    /// selection is known.
    public func shouldApplyWindowBackground(
        surfaceTabId: UUID?,
        owningManagerExists: Bool,
        owningSelectedTabId: UUID?,
        activeSelectedTabId: UUID?
    ) -> Bool {
        guard let surfaceTabId else { return true }
        if owningManagerExists {
            guard let owningSelectedTabId else { return true }
            return owningSelectedTabId == surfaceTabId
        }
        if let activeSelectedTabId {
            return activeSelectedTabId == surfaceTabId
        }
        return true
    }
}
