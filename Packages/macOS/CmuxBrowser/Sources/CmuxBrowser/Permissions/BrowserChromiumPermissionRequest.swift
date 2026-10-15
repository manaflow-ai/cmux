public import Foundation

/// The permissions one Chromium permission prompt asks for: the bits of
/// CEF's `cef_permission_request_types_t` (`OnShowPermissionPrompt`'s
/// `requested_permissions`). A page can group several kinds in one request
/// (camera and microphone for `getUserMedia({video, audio})`).
public struct BrowserChromiumPermissionRequest: OptionSet, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let arSession = Self(rawValue: 1 << 0)
    public static let cameraPanTiltZoom = Self(rawValue: 1 << 1)
    public static let camera = Self(rawValue: 1 << 2)
    public static let capturedSurfaceControl = Self(rawValue: 1 << 3)
    public static let clipboard = Self(rawValue: 1 << 4)
    public static let topLevelStorageAccess = Self(rawValue: 1 << 5)
    public static let diskQuota = Self(rawValue: 1 << 6)
    public static let localFonts = Self(rawValue: 1 << 7)
    public static let geolocation = Self(rawValue: 1 << 8)
    public static let handTracking = Self(rawValue: 1 << 9)
    public static let identityProvider = Self(rawValue: 1 << 10)
    public static let idleDetection = Self(rawValue: 1 << 11)
    public static let microphone = Self(rawValue: 1 << 12)
    public static let midiSysex = Self(rawValue: 1 << 13)
    public static let multipleDownloads = Self(rawValue: 1 << 14)
    public static let notifications = Self(rawValue: 1 << 15)
    public static let keyboardLock = Self(rawValue: 1 << 16)
    public static let pointerLock = Self(rawValue: 1 << 17)
    public static let protectedMediaIdentifier = Self(rawValue: 1 << 18)
    public static let registerProtocolHandler = Self(rawValue: 1 << 19)
    public static let storageAccess = Self(rawValue: 1 << 20)
    public static let vrSession = Self(rawValue: 1 << 21)
    public static let webAppInstallation = Self(rawValue: 1 << 22)
    public static let windowManagement = Self(rawValue: 1 << 23)
    public static let fileSystemAccess = Self(rawValue: 1 << 24)
    public static let localNetworkAccess = Self(rawValue: 1 << 25)
    public static let localNetwork = Self(rawValue: 1 << 26)
    public static let loopbackNetwork = Self(rawValue: 1 << 27)
    public static let sensors = Self(rawValue: 1 << 28)
    public static let ambientLogin = Self(rawValue: 1 << 29)

    /// The request for CEF's media access bits
    /// (`cef_media_access_permission_types_t`, `OnRequestMediaAccessPermission`):
    /// device audio is the microphone, device video the camera. Desktop
    /// capture has no cmux prompt and maps to ``screenCapture``.
    /// - Parameter mediaAccess: The CEF media access bits.
    public init(mediaAccess: UInt32) {
        var request: Self = []
        if mediaAccess & (1 << 0) != 0 { request.insert(.microphone) }
        if mediaAccess & (1 << 1) != 0 { request.insert(.camera) }
        if mediaAccess & ((1 << 2) | (1 << 3)) != 0 { request.insert(.screenCapture) }
        self = request
    }

    /// Desktop audio or video capture from a media access request. Not a CEF
    /// prompt bit (CEF reports it only through media access); bit 31, above
    /// every CEF prompt bit (the highest is 29). Raw prompt bits must come
    /// through ``init(rawValue:)`` masked to ``cefPromptBits``.
    public static let screenCapture = Self(rawValue: 1 << 31)

    /// Every bit CEF may set in `requested_permissions` (bits 0...30).
    public static let cefPromptBits = Self(rawValue: ~(UInt32(1) << 31))

    /// A request from CEF's `OnShowPermissionPrompt` bits; bit 31 is never
    /// taken from CEF, so it cannot pose as ``screenCapture``.
    public init(cefPromptBits: UInt32) {
        self.init(rawValue: cefPromptBits & Self.cefPromptBits.rawValue)
    }

    /// The engine-neutral kinds of this request, in a stable order (camera
    /// before microphone, so one prompt reads "camera and microphone").
    /// Bits without a named ``BrowserPagePermissionRequest/Kind`` become
    /// ``BrowserPagePermissionRequest/Kind/other(_:)`` with their CEF name.
    public var pageKinds: [BrowserPagePermissionRequest.Kind] {
        var kinds: [BrowserPagePermissionRequest.Kind] = []
        var rest = self
        // Pan-tilt-zoom upgrades a camera request (getUserMedia {pan: true}):
        // asked as the camera. Alone it stays its own (denied) kind.
        if rest.contains(.camera) { rest.remove(.cameraPanTiltZoom) }
        for (bit, kind) in Self.namedKinds where contains(bit) {
            kinds.append(kind)
            rest.remove(bit)
        }
        for index in 0..<32 {
            let bit = Self(rawValue: 1 << UInt32(index))
            guard rest.contains(bit) else { continue }
            kinds.append(.other(Self.otherNames[index] ?? "permission-bit-\(index)"))
        }
        return kinds
    }

    /// An engine-neutral request for these kinds from `origin`.
    public func pageRequest(origin: URL?) -> BrowserPagePermissionRequest {
        BrowserPagePermissionRequest(kinds: pageKinds, origin: origin)
    }

    private static let namedKinds: [(Self, BrowserPagePermissionRequest.Kind)] = [
        (.camera, .camera),
        (.microphone, .microphone),
        (.screenCapture, .screenCapture),
        (.geolocation, .geolocation),
        (.notifications, .notifications),
        (.clipboard, .clipboardRead),
        (.midiSysex, .midiSysex),
    ]

    private static let otherNames: [Int: String] = [
        0: "ar-session", 1: "camera-pan-tilt-zoom", 3: "captured-surface-control", 5: "top-level-storage-access",
        6: "disk-quota", 7: "local-fonts", 9: "hand-tracking", 10: "identity-provider", 11: "idle-detection",
        14: "multiple-downloads", 16: "keyboard-lock", 17: "pointer-lock", 18: "protected-media-identifier",
        19: "register-protocol-handler", 20: "storage-access", 21: "vr-session", 22: "web-app-installation",
        23: "window-management", 24: "file-system-access", 25: "local-network-access", 26: "local-network",
        27: "loopback-network", 28: "sensors", 29: "ambient-login",
    ]
}
