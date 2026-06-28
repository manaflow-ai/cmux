/// The localized copy the remote-status update coordinator needs for the
/// `.suspended` reconnect path, resolved app-side and passed down through the
/// host seam.
///
/// `String(localized:)` resolves against the app target's `Localizable.xcstrings`
/// catalog, so it must stay in the app module. The coordinator (in this package)
/// asks the live host for ``RemoteStatusHosting/hostRemoteStatusStrings`` only on
/// the suspended branch and reads the already-resolved values here. The status
/// entry copy is a `String(format:)` template (`"SSH reconnect paused (%@): %@"`)
/// the coordinator formats with the target and detail; the notification title is
/// the fully-resolved `"SSH Reconnect Paused"`. The app-side
/// `RemoteStatusStrings.appLocalized` factory builds this value.
public struct RemoteStatusStrings: Sendable {
    /// The `String(format:)` template for the suspended sidebar status entry,
    /// resolved from `remote.statusEntry.suspended`. Carries two `%@`
    /// placeholders: the remote target, then the trimmed detail.
    public let suspendedStatusEntryFormat: String

    /// The resolved title for the suspended reconnect notification, from
    /// `remote.notification.suspendedTitle`.
    public let suspendedNotificationTitle: String

    /// Creates a resolved remote-status string bundle.
    public init(
        suspendedStatusEntryFormat: String,
        suspendedNotificationTitle: String
    ) {
        self.suspendedStatusEntryFormat = suspendedStatusEntryFormat
        self.suspendedNotificationTitle = suspendedNotificationTitle
    }
}
