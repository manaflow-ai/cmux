import Foundation

/// What a PERMISSION_PROMPT asks (`CEFShim/src/permission_prompt_policy.h`):
/// the event's `a` holds the `cef_permission_request_types_t` bits of
/// `OnShowPermissionPrompt`. Screen sharing is not one: it keeps Chromium's
/// desktop media picker path.
nonisolated struct CEFPermissionRequest: Equatable, Sendable {
    let bits: Int64

    /// `CEF_PERMISSION_TYPE_GEOLOCATION`.
    static let geolocation: Int64 = 1 << 8
    /// `CEF_PERMISSION_TYPE_NOTIFICATIONS`.
    static let notifications: Int64 = 1 << 15

    /// `cef_permission_request_types_t`, bit by bit (CEF 154: AR_SESSION 1 << 0
    /// to SENSORS 1 << 28). LOCAL_NETWORK_ACCESS (1 << 25) and LOCAL_NETWORK
    /// (1 << 26) ask the same thing.
    static let promptItems: [BrowserSiteCapability] = [
        .arSession, .cameraPanTiltZoom, .camera, .capturedSurfaceControl, .clipboard, .topLevelStorageAccess,
        .diskQuota, .localFonts, .location, .handTracking, .identityProvider, .idleDetection, .microphone,
        .midiSysex, .multipleDownloads, .notifications, .keyboardLock, .pointerLock, .protectedMediaIdentifier,
        .registerProtocolHandler, .storageAccess, .vrSession, .webAppInstallation, .windowManagement,
        .fileSystemAccess, .localNetwork, .localNetwork, .loopbackNetwork, .sensors,
    ]

    /// `permissions` is the event's `a`.
    init(permissions: Int64) {
        bits = permissions
    }

    /// The question the prompt bar asks; nil when the request carries a bit
    /// cmux does not know (it is left unanswered, as a closed tab's is).
    var kind: BrowserPermissionKind? {
        if bits == Self.geolocation { return .location }
        // Reached once Chromium's notifications are routed to cmux; until then
        // `disable-notifications` (CEFSwitches) keeps the page's API off.
        if bits == Self.notifications { return .notifications }
        return items.map(BrowserPermissionKind.capabilities)
    }

    /// The prompt's items in CEF's bit order, each once; nil for no bits or
    /// for a bit past the table.
    private var items: [BrowserSiteCapability]? {
        guard bits > 0, bits >> Self.promptItems.count == 0 else { return nil }
        var items: [BrowserSiteCapability] = []
        for (bit, item) in Self.promptItems.enumerated() where bits & (Int64(1) << bit) != 0 && !items.contains(item) {
            items.append(item)
        }
        return items
    }
}
