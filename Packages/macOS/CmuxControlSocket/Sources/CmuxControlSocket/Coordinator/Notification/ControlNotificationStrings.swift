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
    /// Invalid non-null `caller` selector in a clear request.
    public let clearCallerInvalid: String
    /// Caller-only selectors used without an explicit caller mode.
    public let clearCallerSelectorsRequireCaller: String
    /// Incompatible caller and workspace/surface selectors in a clear request.
    public let clearCallerScopeConflict: String
    /// Invalid preferred workspace selector in a caller clear request.
    public let clearPreferredWorkspaceIDInvalid: String
    /// Invalid preferred surface selector in a caller clear request.
    public let clearPreferredSurfaceIDInvalid: String
    /// A surface clear request without its required workspace selector.
    public let clearSurfaceIDRequiresWorkspace: String
    /// Invalid workspace selector in a scoped clear request.
    public let clearWorkspaceIDInvalid: String
    /// The legacy notification coordinator's workspace-not-found message.
    public let workspaceNotFound: String
    /// The legacy notification coordinator's surface-not-found message.
    public let surfaceNotFound: String
    /// Product-level message for a scoped clear that cannot reach notifications.
    public let clearUnavailable: String

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
    ///   - clearCallerInvalid: The invalid-caller message.
    ///   - clearCallerSelectorsRequireCaller: The caller-selector mode message.
    ///   - clearCallerScopeConflict: The caller-scope-conflict message.
    ///   - clearPreferredWorkspaceIDInvalid: The invalid-preferred-workspace message.
    ///   - clearPreferredSurfaceIDInvalid: The invalid-preferred-surface message.
    ///   - clearSurfaceIDRequiresWorkspace: The clear-surface-requires-workspace message.
    ///   - clearWorkspaceIDInvalid: The invalid-clear-workspace message.
    ///   - workspaceNotFound: The workspace-not-found message.
    ///   - surfaceNotFound: The surface-not-found message.
    ///   - clearUnavailable: The product-level scoped-clear unavailable message.
    public init(
        dismissSelectorRequired: String,
        idRequired: String,
        notFound: String,
        markReadSelectorRequired: String,
        surfaceIDInvalid: String,
        surfaceIDRequiresWorkspace: String,
        targetNotFound: String,
        clearCallerInvalid: String,
        clearCallerSelectorsRequireCaller: String,
        clearCallerScopeConflict: String,
        clearPreferredWorkspaceIDInvalid: String,
        clearPreferredSurfaceIDInvalid: String,
        clearSurfaceIDRequiresWorkspace: String,
        clearWorkspaceIDInvalid: String,
        workspaceNotFound: String = "Workspace not found",
        surfaceNotFound: String = "Surface not found",
        clearUnavailable: String = "Notifications are unavailable. Try again."
    ) {
        self.dismissSelectorRequired = dismissSelectorRequired
        self.idRequired = idRequired
        self.notFound = notFound
        self.markReadSelectorRequired = markReadSelectorRequired
        self.surfaceIDInvalid = surfaceIDInvalid
        self.surfaceIDRequiresWorkspace = surfaceIDRequiresWorkspace
        self.targetNotFound = targetNotFound
        self.clearCallerInvalid = clearCallerInvalid
        self.clearCallerSelectorsRequireCaller = clearCallerSelectorsRequireCaller
        self.clearCallerScopeConflict = clearCallerScopeConflict
        self.clearPreferredWorkspaceIDInvalid = clearPreferredWorkspaceIDInvalid
        self.clearPreferredSurfaceIDInvalid = clearPreferredSurfaceIDInvalid
        self.clearSurfaceIDRequiresWorkspace = clearSurfaceIDRequiresWorkspace
        self.clearWorkspaceIDInvalid = clearWorkspaceIDInvalid
        self.workspaceNotFound = workspaceNotFound
        self.surfaceNotFound = surfaceNotFound
        self.clearUnavailable = clearUnavailable
    }
}
