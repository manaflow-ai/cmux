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
    /// Creates a pure root authentication gate policy value.
    public init() {}

    /// Backwards-compatible nested spelling for root content destinations.
    public typealias RootContentDestination = MobileRootContentDestination

    /// Backwards-compatible static spelling for ``isAuthenticated(stackAuthenticated:attachTicketAuthenticated:)``.
    public static func isAuthenticated(
        stackAuthenticated: Bool,
        attachTicketAuthenticated: Bool = false
    ) -> Bool {
        MobileRootAuthGate().isAuthenticated(
            stackAuthenticated: stackAuthenticated,
            attachTicketAuthenticated: attachTicketAuthenticated
        )
    }

    /// Backwards-compatible static spelling for ``shouldShowRestoringSession(stackAuthenticated:attachTicketAuthenticated:isRestoringSession:)``.
    public static func shouldShowRestoringSession(
        stackAuthenticated: Bool,
        attachTicketAuthenticated: Bool = false,
        isRestoringSession: Bool
    ) -> Bool {
        MobileRootAuthGate().shouldShowRestoringSession(
            stackAuthenticated: stackAuthenticated,
            attachTicketAuthenticated: attachTicketAuthenticated,
            isRestoringSession: isRestoringSession
        )
    }

    /// Backwards-compatible static spelling for ``isAttachURL(_:)``.
    public static func isAttachURL(_ url: URL) -> Bool {
        MobileRootAuthGate().isAttachURL(url)
    }

    /// Backwards-compatible static spelling for ``shouldClearAttachTicketAuthentication(pairingResult:connectionState:hasActiveUnexpiredTicket:)``.
    public static func shouldClearAttachTicketAuthentication(
        pairingResult: MobilePairingURLConnectionResult,
        connectionState: MobileConnectionState,
        hasActiveUnexpiredTicket: Bool
    ) -> Bool {
        MobileRootAuthGate().shouldClearAttachTicketAuthentication(
            pairingResult: pairingResult,
            connectionState: connectionState,
            hasActiveUnexpiredTicket: hasActiveUnexpiredTicket
        )
    }

    /// Backwards-compatible static spelling for ``shouldReconnectStoredMac(stackAuthenticated:attachTicketAuthenticated:connectionState:)``.
    public static func shouldReconnectStoredMac(
        stackAuthenticated: Bool,
        attachTicketAuthenticated: Bool,
        connectionState: MobileConnectionState
    ) -> Bool {
        MobileRootAuthGate().shouldReconnectStoredMac(
            stackAuthenticated: stackAuthenticated,
            attachTicketAuthenticated: attachTicketAuthenticated,
            connectionState: connectionState
        )
    }

    /// Backwards-compatible static spelling for ``shouldShowRestoringStoredMac(authenticated:connectionState:isReconnectingStoredMac:hasKnownPairedMac:pairedMacHintUndetermined:didFinishStoredMacReconnectAttempt:)``.
    public static func shouldShowRestoringStoredMac(
        authenticated: Bool,
        connectionState: MobileConnectionState,
        isReconnectingStoredMac: Bool,
        hasKnownPairedMac: Bool,
        pairedMacHintUndetermined: Bool,
        didFinishStoredMacReconnectAttempt: Bool
    ) -> Bool {
        MobileRootAuthGate().shouldShowRestoringStoredMac(
            authenticated: authenticated,
            connectionState: connectionState,
            isReconnectingStoredMac: isReconnectingStoredMac,
            hasKnownPairedMac: hasKnownPairedMac,
            pairedMacHintUndetermined: pairedMacHintUndetermined,
            didFinishStoredMacReconnectAttempt: didFinishStoredMacReconnectAttempt
        )
    }

    /// Backwards-compatible static spelling for ``rootContentDestination(showsTerminalLayoutPreview:showsWorkspaceListLayoutPreview:showsRestoringSession:authenticated:preservesWorkspaceShellDuringReconnect:connectionState:showsRestoringStoredMac:hasKnownPairedMac:isReconnectingStoredMac:showsOnboarding:)``.
    public static func rootContentDestination(
        showsTerminalLayoutPreview: Bool,
        showsWorkspaceListLayoutPreview: Bool,
        showsRestoringSession: Bool,
        authenticated: Bool,
        preservesWorkspaceShellDuringReconnect: Bool,
        connectionState: MobileConnectionState,
        showsRestoringStoredMac: Bool,
        hasKnownPairedMac: Bool,
        isReconnectingStoredMac: Bool,
        showsOnboarding: Bool
    ) -> RootContentDestination {
        MobileRootAuthGate().rootContentDestination(
            showsTerminalLayoutPreview: showsTerminalLayoutPreview,
            showsWorkspaceListLayoutPreview: showsWorkspaceListLayoutPreview,
            showsRestoringSession: showsRestoringSession,
            authenticated: authenticated,
            preservesWorkspaceShellDuringReconnect: preservesWorkspaceShellDuringReconnect,
            connectionState: connectionState,
            showsRestoringStoredMac: showsRestoringStoredMac,
            hasKnownPairedMac: hasKnownPairedMac,
            isReconnectingStoredMac: isReconnectingStoredMac,
            showsOnboarding: showsOnboarding
        )
    }

    /// Whether the user is authenticated by either Stack auth or an attach ticket.
    /// - Parameters:
    ///   - stackAuthenticated: Whether Stack auth is established.
    ///   - attachTicketAuthenticated: Whether a temporary attach ticket grants access. Defaults to `false`.
    /// - Returns: `true` when either source authenticates the user.
    public func isAuthenticated(
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
    public func shouldShowRestoringSession(
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
    public func isAttachURL(_ url: URL) -> Bool {
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
    public func shouldClearAttachTicketAuthentication(
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
    ///   - connectionState: The current connection state.
    /// - Returns: `true` when Stack-authenticated without a temporary ticket and not yet connected.
    public func shouldReconnectStoredMac(
        stackAuthenticated: Bool,
        attachTicketAuthenticated: Bool,
        connectionState: MobileConnectionState
    ) -> Bool {
        stackAuthenticated && !attachTicketAuthenticated && connectionState != .connected
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
    public func shouldShowRestoringStoredMac(
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

    /// Pure root-view branch selection. Keeping this order executable in tests is
    /// what protects the terminal reconnect path: once a real remote terminal
    /// snapshot is cached, transient reconnects must keep the workspace shell
    /// mounted so the Ghostty surface and PTY mirror retain their last frame.
    public func rootContentDestination(
        showsTerminalLayoutPreview: Bool,
        showsWorkspaceListLayoutPreview: Bool,
        showsRestoringSession: Bool,
        authenticated: Bool,
        preservesWorkspaceShellDuringReconnect: Bool,
        connectionState: MobileConnectionState,
        showsRestoringStoredMac: Bool,
        hasKnownPairedMac: Bool,
        isReconnectingStoredMac: Bool,
        showsOnboarding: Bool
    ) -> RootContentDestination {
        if showsTerminalLayoutPreview {
            return .terminalLayoutPreview
        }
        if showsWorkspaceListLayoutPreview {
            return .workspaceListLayoutPreview
        }
        if showsRestoringSession {
            return .restoringSession
        }
        if !authenticated {
            return .signIn
        }
        if preservesWorkspaceShellDuringReconnect {
            return .workspaceShell
        }
        if connectionState != .connected, showsRestoringStoredMac {
            return hasKnownPairedMac || isReconnectingStoredMac
                ? .restoringStoredMac
                : .pairedMacDetermining
        }
        if showsOnboarding {
            return .onboarding
        }
        if connectionState != .connected {
            return .disconnectedWorkspaceShell
        }
        return .workspaceShell
    }
}
