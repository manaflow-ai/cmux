/// User-facing connection-lifecycle strings the coordinator projects into the
/// sidebar, notifications, and the disconnected-detail text, resolved app-side
/// so `String(localized:)` binds to the app bundle's localization tables (the
/// package never localizes). Keys and default values are identical to the
/// legacy `Workspace` inline `String(localized:)` calls.
public struct RemoteConnectionStrings: Sendable, Equatable {
    /// The disconnected detail shown after a remote terminal session exits
    /// (`remote.status.terminalDisconnected`).
    public let terminalDisconnectedDetail: String
    /// Format for the suspended-reconnect sidebar status entry
    /// (`remote.statusEntry.suspended`); `%@` is the target then the detail.
    public let suspendedStatusEntryFormat: String
    /// The suspended-reconnect notification title
    /// (`remote.notification.suspendedTitle`).
    public let suspendedNotificationTitle: String
    /// Format for the disconnect-placeholder "session ended" banner line,
    /// rendered by the POSIX `printf` inside the shell wrapper, so it uses `%s`
    /// (not `%@`) and is fed the target as its single argument
    /// (`remote.disconnectBanner.sessionEnded`).
    public let disconnectBannerSessionEndedFormat: String
    /// The disconnect-placeholder reconnect-hint banner line
    /// (`remote.disconnectBanner.reconnectHint`).
    public let disconnectBannerReconnectHint: String
    /// The disconnect-placeholder reconnect-unavailable-hint banner line
    /// (`remote.disconnectBanner.reconnectUnavailableHint`).
    public let disconnectBannerReconnectUnavailableHint: String

    /// Creates the connection-strings bundle with every value app-resolved.
    public init(
        terminalDisconnectedDetail: String,
        suspendedStatusEntryFormat: String,
        suspendedNotificationTitle: String,
        disconnectBannerSessionEndedFormat: String,
        disconnectBannerReconnectHint: String,
        disconnectBannerReconnectUnavailableHint: String
    ) {
        self.terminalDisconnectedDetail = terminalDisconnectedDetail
        self.suspendedStatusEntryFormat = suspendedStatusEntryFormat
        self.suspendedNotificationTitle = suspendedNotificationTitle
        self.disconnectBannerSessionEndedFormat = disconnectBannerSessionEndedFormat
        self.disconnectBannerReconnectHint = disconnectBannerReconnectHint
        self.disconnectBannerReconnectUnavailableHint = disconnectBannerReconnectUnavailableHint
    }
}
