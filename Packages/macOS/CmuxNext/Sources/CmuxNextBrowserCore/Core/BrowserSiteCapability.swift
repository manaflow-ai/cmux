/// One thing a page asks Chromium to allow (Chromium's `permissions::RequestType`,
/// CEF's `cef_permission_request_types_t`), as Chrome's permission bubble lists it
/// (`permissions::GetMessageTextFragment`, components/permissions/request_type.cc).
public nonisolated enum BrowserSiteCapability: String, CaseIterable, Hashable, Sendable {
    case arSession
    case cameraPanTiltZoom
    case camera
    case capturedSurfaceControl
    case clipboard
    case topLevelStorageAccess
    case diskQuota
    case localFonts
    case location
    case handTracking
    case identityProvider
    case idleDetection
    case microphone
    case midiSysex
    case multipleDownloads
    case notifications
    case keyboardLock
    case pointerLock
    case protectedMediaIdentifier
    case registerProtocolHandler
    case storageAccess
    case vrSession
    case webAppInstallation
    case windowManagement
    case fileSystemAccess
    case localNetwork
    case loopbackNetwork
    case sensors

    /// The per-site setting cmux keeps for it (Page Info), or nil when only
    /// Chromium remembers the answer.
    public var siteKind: SitePermissionKind? {
        switch self {
        case .location: .location
        case .camera: .camera
        case .microphone: .microphone
        case .notifications: .notifications
        case .clipboard: .clipboard
        case .localFonts: .localFonts
        case .midiSysex: .midi
        case .windowManagement: .windowManagement
        case .sensors: .sensors
        case .arSession, .cameraPanTiltZoom, .capturedSurfaceControl, .topLevelStorageAccess, .diskQuota,
             .handTracking, .identityProvider, .idleDetection, .multipleDownloads, .keyboardLock, .pointerLock,
             .protectedMediaIdentifier, .registerProtocolHandler, .storageAccess, .vrSession,
             .webAppInstallation, .fileSystemAccess, .localNetwork, .loopbackNetwork:
            nil
        }
    }
}
