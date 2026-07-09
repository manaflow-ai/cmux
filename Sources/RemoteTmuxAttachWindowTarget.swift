import Foundation

/// Window-routing intent for a remote-tmux attach, preserved across SSH awaits.
enum RemoteTmuxAttachWindowTarget: Sendable, Equatable {
    /// A non-null `window_id` that resolved when the request was parsed.
    case explicitWindow(UUID)
    /// A non-null `window_id` that did not resolve.
    case unresolvedExplicitWindow
    /// Contextual routing (group/workspace/surface/pane/caller), which may fall
    /// back to the active window if its preferred window disappears.
    case contextualWindow(UUID?)

    /// Resolves the live destination while preserving existing-host affinity.
    func resolve(
        existingMirrorWindowID: UUID?,
        activeWindowID: UUID?,
        isLive: (UUID) -> Bool
    ) -> UUID? {
        if let existingMirrorWindowID, isLive(existingMirrorWindowID) {
            return existingMirrorWindowID
        }
        switch self {
        case .explicitWindow(let windowID):
            if isLive(windowID) { return windowID }
        case .unresolvedExplicitWindow:
            break
        case .contextualWindow(let preferredWindowID):
            if let preferredWindowID, isLive(preferredWindowID) {
                return preferredWindowID
            }
        }
        guard let activeWindowID, isLive(activeWindowID) else { return nil }
        return activeWindowID
    }
}
