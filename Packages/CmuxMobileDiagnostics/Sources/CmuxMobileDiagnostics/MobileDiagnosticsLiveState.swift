import Foundation

/// A decoupled snapshot of the mobile shell's live runtime state, passed into
/// ``MobileDiagnosticsReportBuilder`` so the diagnostics package never depends
/// on the shell, auth, or paired-Mac packages.
///
/// The caller (the workspace detail view) maps its concrete shell/auth/pairing
/// types into these plain, ``Sendable`` fields. Everything here is already a
/// display string or boolean, so the report builder only has to format it.
public struct MobileDiagnosticsLiveState: Sendable {
    /// Human-readable connection state (e.g. `"connected"` / `"disconnected"`).
    public let connectionState: String
    /// Whether the shell considers the session signed in.
    public let isSignedIn: Bool
    /// Whether the auth coordinator reports an authenticated Stack session.
    public let isAuthenticated: Bool
    /// Last display-safe auth error, if any.
    public let lastAuthError: String?
    /// Name/host of the connected Mac, if any (already display-safe).
    public let connectedHostName: String?
    /// Display name of the paired Mac, if a pairing is recorded.
    public let pairedMacName: String?
    /// Stable device id of the paired Mac, if a pairing is recorded.
    public let pairedMacDeviceID: String?
    /// The last connection error message surfaced to the user, if any.
    public let connectionError: String?

    /// Creates a live-state snapshot.
    ///
    /// - Parameters:
    ///   - connectionState: Human-readable connection state.
    ///   - isSignedIn: Whether the shell considers the session signed in.
    ///   - isAuthenticated: Whether auth reports an authenticated session.
    ///   - lastAuthError: Last display-safe auth error, if any.
    ///   - connectedHostName: Name/host of the connected Mac, if any.
    ///   - pairedMacName: Display name of the paired Mac, if any.
    ///   - pairedMacDeviceID: Device id of the paired Mac, if any.
    ///   - connectionError: Last surfaced connection error, if any.
    public init(
        connectionState: String,
        isSignedIn: Bool,
        isAuthenticated: Bool,
        lastAuthError: String? = nil,
        connectedHostName: String?,
        pairedMacName: String?,
        pairedMacDeviceID: String?,
        connectionError: String?
    ) {
        self.connectionState = connectionState
        self.isSignedIn = isSignedIn
        self.isAuthenticated = isAuthenticated
        self.lastAuthError = lastAuthError
        self.connectedHostName = connectedHostName
        self.pairedMacName = pairedMacName
        self.pairedMacDeviceID = pairedMacDeviceID
        self.connectionError = connectionError
    }
}
