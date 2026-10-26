import Foundation

/// What a PERMISSION_PROMPT asks (`CEFShim/src/permission_prompt_policy.h`):
/// the event's `a` holds `cef_permission_request_types_t` bits from
/// `OnShowPermissionPrompt` as they are, or `cef_media_access_permission_types_t`
/// bits from `OnRequestMediaAccessPermission` (screen sharing) above bit 32
/// (`MediaPromptBits`).
nonisolated struct CEFPermissionRequest: Equatable, Sendable {
    nonisolated enum Source: Equatable, Sendable {
        case prompt
        case media
    }

    let source: Source
    let bits: Int64

    /// `CEF_PERMISSION_TYPE_GEOLOCATION`.
    static let geolocation: Int64 = 1 << 8
    /// `CEF_PERMISSION_TYPE_NOTIFICATIONS`.
    static let notifications: Int64 = 1 << 15
    /// `CEF_MEDIA_PERMISSION_DESKTOP_AUDIO_CAPTURE`, `CEF_MEDIA_PERMISSION_DESKTOP_VIDEO_CAPTURE`.
    static let desktopAudio: Int64 = 1 << 2
    static let desktopVideo: Int64 = 1 << 3

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
        let media = permissions >> 32
        source = media != 0 ? .media : .prompt
        bits = media != 0 ? media : permissions
    }

    /// The question the prompt bar asks; nil when the request carries a bit
    /// cmux does not know (it is left unanswered, as a closed tab's is).
    var kind: BrowserPermissionKind? {
        switch source {
        case .media:
            let desktop = Self.desktopAudio | Self.desktopVideo
            return bits & Self.desktopVideo != 0 && bits & ~desktop == 0 ? .screen : nil
        case .prompt:
            if bits == Self.geolocation { return .location }
            if bits == Self.notifications { return .notifications }
            return items.map(BrowserPermissionKind.capabilities)
        }
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
