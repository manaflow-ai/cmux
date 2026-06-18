/// The localized notification-domain error messages, supplied by the app
/// conformance so they resolve against the app's `Localizable.xcstrings`.
///
/// The coordinator builds the error envelopes (it owns the selector
/// validation), but the strings must keep their existing keys + default values
/// and their per-locale translations. Resolving `String(localized:)` inside the
/// package would bind to the package bundle, which lacks these keys, silently
/// dropping the non-English variants — so the app passes the already-resolved
/// strings across the seam instead.
public struct ControlNotificationStrings: Sendable, Equatable {
    /// `socket.notification.dismissSelectorRequired` —
    /// "Select exactly one of id or all_read".
    public let dismissSelectorRequired: String
    /// `socket.notification.idRequired` — "Missing or invalid notification id".
    public let idRequired: String
    /// `socket.notification.notFound` — "Notification not found".
    public let notFound: String
    /// `socket.notification.markReadSelectorRequired` —
    /// "Select exactly one of id, tab_id, or all".
    public let markReadSelectorRequired: String
    /// `socket.notification.surfaceIdInvalid` — "Missing or invalid surface_id".
    public let surfaceIDInvalid: String
    /// `socket.notification.surfaceIdRequiresWorkspace` —
    /// "surface_id requires tab_id or workspace_id".
    public let surfaceIDRequiresWorkspace: String
    /// `socket.notification.targetNotFound` — "Notification target not found".
    public let targetNotFound: String

    /// Creates the localized message bundle.
    ///
    /// - Parameters:
    ///   - dismissSelectorRequired: The dismiss-selector-required message.
    ///   - idRequired: The id-required message.
    ///   - notFound: The notification-not-found message.
    ///   - markReadSelectorRequired: The mark-read-selector-required message.
    ///   - surfaceIDInvalid: The invalid-surface_id message.
    ///   - surfaceIDRequiresWorkspace: The surface_id-requires-workspace message.
    ///   - targetNotFound: The target-not-found message.
    public init(
        dismissSelectorRequired: String,
        idRequired: String,
        notFound: String,
        markReadSelectorRequired: String,
        surfaceIDInvalid: String,
        surfaceIDRequiresWorkspace: String,
        targetNotFound: String
    ) {
        self.dismissSelectorRequired = dismissSelectorRequired
        self.idRequired = idRequired
        self.notFound = notFound
        self.markReadSelectorRequired = markReadSelectorRequired
        self.surfaceIDInvalid = surfaceIDInvalid
        self.surfaceIDRequiresWorkspace = surfaceIDRequiresWorkspace
        self.targetNotFound = targetNotFound
    }
}
