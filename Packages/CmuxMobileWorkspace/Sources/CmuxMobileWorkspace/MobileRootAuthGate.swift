public import CmuxMobileShellModel
public import Foundation

/// Pure authentication-gating policy for the mobile root scene.
///
/// Combines Stack auth and temporary attach-ticket auth into the booleans the root
/// scene branches on (authenticated, restoring, attach-URL recognition, and whether
/// stale attach auth should be cleared or a stored Mac reconnected). All members are
/// pure functions so the root scene's gating logic can be tested without a store.
public enum MobileRootAuthGate {
    /// Whether the user is authenticated by either Stack auth or an attach ticket.
    /// - Parameters:
    ///   - stackAuthenticated: Whether Stack auth is established.
    ///   - attachTicketAuthenticated: Whether a temporary attach ticket grants access. Defaults to `false`.
    /// - Returns: `true` when either source authenticates the user.
    public static func isAuthenticated(
        stackAuthenticated: Bool,
        attachTicketAuthenticated: Bool = false
    ) -> Bool {
        stackAuthenticated || attachTicketAuthenticated
    }

    /// Whether the restoring-session UI should be shown.
    /// - Parameters:
    ///   - stackAuthenticated: Whether Stack auth is established.
    ///   - attachTicketAuthenticated: Whether a temporary attach ticket grants access. Defaults to `false`.
    ///   - isRestoringSession: Whether a session restore is in progress.
    /// - Returns: `true` only while restoring and not yet authenticated.
    public static func shouldShowRestoringSession(
        stackAuthenticated: Bool,
        attachTicketAuthenticated: Bool = false,
        isRestoringSession: Bool
    ) -> Bool {
        isRestoringSession && !isAuthenticated(
            stackAuthenticated: stackAuthenticated,
            attachTicketAuthenticated: attachTicketAuthenticated
        )
    }

    /// Whether a URL is a cmux attach deep link (`cmux-ios://attach`).
    /// - Parameter url: The URL to classify.
    /// - Returns: `true` when the URL is an attach deep link.
    public static func isAttachURL(_ url: URL) -> Bool {
        guard url.scheme?.caseInsensitiveCompare("cmux-ios") == .orderedSame else {
            return false
        }
        return url.host?.caseInsensitiveCompare("attach") == .orderedSame
    }

    /// Whether stale temporary attach-ticket authentication should be cleared.
    /// - Parameters:
    ///   - pairingResult: The result of the most recent pairing-URL connection.
    ///   - connectionState: The current connection state.
    ///   - hasActiveUnexpiredTicket: Whether a non-expired attach ticket is still active.
    /// - Returns: `true` when the attach auth is no longer backed by a live, ticketed connection.
    public static func shouldClearAttachTicketAuthentication(
        pairingResult: MobilePairingURLConnectionResult,
        connectionState: MobileConnectionState,
        hasActiveUnexpiredTicket: Bool
    ) -> Bool {
        switch pairingResult {
        case .connected:
            return connectionState != .connected || !hasActiveUnexpiredTicket
        case .failed:
            return true
        case .superseded:
            return connectionState != .connected || !hasActiveUnexpiredTicket
        }
    }

    /// Whether a previously stored Mac should be reconnected automatically.
    /// - Parameters:
    ///   - stackAuthenticated: Whether Stack auth is established.
    ///   - attachTicketAuthenticated: Whether a temporary attach ticket grants access.
    ///   - connectionState: The current connection state.
    /// - Returns: `true` when Stack-authenticated without a temporary ticket and not yet connected.
    public static func shouldReconnectStoredMac(
        stackAuthenticated: Bool,
        attachTicketAuthenticated: Bool,
        connectionState: MobileConnectionState
    ) -> Bool {
        stackAuthenticated && !attachTicketAuthenticated && connectionState != .connected
    }
}
