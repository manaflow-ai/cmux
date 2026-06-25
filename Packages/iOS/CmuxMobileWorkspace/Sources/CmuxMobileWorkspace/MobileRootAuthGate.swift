internal import CMUXMobileCore
public import CmuxMobileShellModel
public import Foundation

/// Pure authentication-gating policy for the mobile root scene.
///
/// Combines Stack auth and temporary attach-ticket auth into the booleans the root
/// scene branches on (authenticated, restoring, attach-URL recognition, and whether
/// stale attach auth should be cleared or a stored Mac reconnected). All members are
/// pure functions so the root scene's gating logic can be tested without a store.
public struct MobileRootAuthGate {
    private init() {}

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

    /// Whether a URL is a cmux attach deep link (a `<scheme>://attach` URL in
    /// any channel's pairing scheme; see ``CmxPairingURLScheme``).
    /// - Parameter url: The URL to classify.
    /// - Returns: `true` when the URL is an attach deep link.
    public static func isAttachURL(_ url: URL) -> Bool {
        guard CmxPairingURLScheme.isPairingScheme(url.scheme) else {
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
        case .needsUserApproval:
            return false
        case .superseded:
            return connectionState != .connected || !hasActiveUnexpiredTicket
        }
    }

    /// Whether a previously stored Mac should be reconnected automatically.
    /// - Parameters:
    ///   - stackAuthenticated: Whether Stack auth is established.
    ///   - attachTicketAuthenticated: Whether a temporary attach ticket grants access.
    ///   - attachURLConnectionInProgress: Whether a launch/deep-link attach URL is already connecting.
    ///   - connectionState: The current connection state.
    /// - Returns: `true` when Stack-authenticated without a temporary ticket and not yet connected.
    public static func shouldReconnectStoredMac(
        stackAuthenticated: Bool,
        attachTicketAuthenticated: Bool,
        attachURLConnectionInProgress: Bool = false,
        connectionState: MobileConnectionState
    ) -> Bool {
        stackAuthenticated
            && !attachTicketAuthenticated
            && !attachURLConnectionInProgress
            && connectionState != .connected
    }

    /// Whether the root should wait for Stack's concrete user id before deciding
    /// there are no saved Macs.
    ///
    /// Paired-Mac backup restore is scoped by Stack user/team. During cached
    /// session restore, `isAuthenticated` can become true before the user object
    /// has been published. Treating that gap as "no paired Mac" makes returning
    /// users see the Add Device sheet even though backup restore would find their
    /// existing Macs once the account scope arrives.
    /// - Parameters:
    ///   - stackAuthenticated: Whether Stack auth is established.
    ///   - attachTicketAuthenticated: Whether a temporary attach ticket grants access.
    ///   - connectionState: The current connection state.
    ///   - currentUserID: The Stack user id used to scope paired-Mac restore.
    /// - Returns: `true` while Stack-authenticated, not attach-ticket authenticated,
    ///   disconnected, and the Stack user id is still missing or blank.
    public static func shouldWaitForAuthenticatedUserScope(
        stackAuthenticated: Bool,
        attachTicketAuthenticated: Bool,
        connectionState: MobileConnectionState,
        currentUserID: String?
    ) -> Bool {
        guard stackAuthenticated, !attachTicketAuthenticated, connectionState != .connected else {
            return false
        }
        let trimmedUserID = currentUserID?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedUserID?.isEmpty ?? true
    }

    /// Whether the restoring-session UI should be shown while reconnecting a known
    /// paired Mac.
    ///
    /// A returning user (already authenticated, previously paired) should see the
    /// existing "Restoring session…" state during the reconnect window instead of
    /// the empty add-device sheet. A genuinely never-paired user still falls
    /// through to add-device immediately. The persisted ``hasKnownPairedMac`` hint
    /// covers the very first rendered frame before the async paired-Mac read runs.
    /// ``pairedMacHintUndetermined`` covers installs that predate the hint (the key
    /// was never written but a Mac may already exist in the paired-Mac store): they
    /// are treated as "may have a paired Mac" until the first reconnect attempt
    /// resolves and writes the hint, so they do not flash add-device on the first
    /// launch after updating. ``didFinishStoredMacReconnectAttempt`` lets a failed or
    /// offline attempt fall through to the disconnected view instead of spinning.
    /// - Parameters:
    ///   - authenticated: Whether the user is authenticated (Stack or attach ticket).
    ///   - connectionState: The current connection state.
    ///   - isReconnectingStoredMac: Whether a found stored Mac is actively mid-reconnect.
    ///   - hasKnownPairedMac: The persisted hint that this device has paired a Mac before.
    ///   - pairedMacHintUndetermined: Whether the hint has never been written on this install (key absent).
    ///   - didFinishStoredMacReconnectAttempt: Whether the first launch reconnect attempt has resolved.
    /// - Returns: `true` while authenticated, not yet connected, and either actively
    ///   reconnecting a stored Mac or — before the first attempt resolves — holding
    ///   the paired-Mac hint or an undetermined hint.
    public static func shouldShowRestoringStoredMac(
        authenticated: Bool,
        connectionState: MobileConnectionState,
        isReconnectingStoredMac: Bool,
        hasKnownPairedMac: Bool,
        pairedMacHintUndetermined: Bool,
        didFinishStoredMacReconnectAttempt: Bool
    ) -> Bool {
        guard authenticated, connectionState != .connected else { return false }
        if isReconnectingStoredMac { return true }
        guard !didFinishStoredMacReconnectAttempt else { return false }
        return hasKnownPairedMac || pairedMacHintUndetermined
    }
}
