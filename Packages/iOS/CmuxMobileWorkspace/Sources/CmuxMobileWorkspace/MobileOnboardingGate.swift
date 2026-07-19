/// Pure routing policy for the three stages of mobile onboarding.
public struct MobileOnboardingGate {
    private init() {}

    /// Returns whether signed-out users should see the pre-auth welcome pages.
    ///
    /// - Parameters:
    ///   - isAuthenticated: Whether the current root session is authenticated.
    ///   - hasSeenWelcome: Whether this install already completed or skipped the welcome pages.
    /// - Returns: `true` only for a signed-out install that has never seen welcome.
    public static func shouldShowWelcome(
        isAuthenticated: Bool,
        hasSeenWelcome: Bool
    ) -> Bool {
        !isAuthenticated && !hasSeenWelcome
    }

    /// Returns whether a signed-in user must connect their first Mac.
    ///
    /// - Parameters:
    ///   - isAuthenticated: Whether the current root session is authenticated.
    ///   - isConnected: Whether a Mac connection is currently active.
    ///   - hasKnownPairedMac: Whether a saved or restored paired Mac is known.
    ///   - hasCompletedConnect: Whether this install previously completed its first connection.
    /// - Returns: `true` only for a signed-in, disconnected, never-paired install that has not completed connection.
    public static func shouldShowConnect(
        isAuthenticated: Bool,
        isConnected: Bool,
        hasKnownPairedMac: Bool,
        hasCompletedConnect: Bool
    ) -> Bool {
        isAuthenticated && !isConnected && !hasKnownPairedMac && !hasCompletedConnect
    }

    /// Returns whether a connected user should see the one-time push primer.
    ///
    /// - Parameters:
    ///   - isConnected: Whether a Mac connection is currently active.
    ///   - hasPrimedNotifications: Whether the primer has already been shown.
    ///   - isPushEnabled: Whether push notifications are already enabled.
    /// - Returns: `true` only after connection when the primer is unseen and push is disabled.
    public static func shouldPrimeNotifications(
        isConnected: Bool,
        hasPrimedNotifications: Bool,
        isPushEnabled: Bool
    ) -> Bool {
        isConnected && !hasPrimedNotifications && !isPushEnabled
    }
}
