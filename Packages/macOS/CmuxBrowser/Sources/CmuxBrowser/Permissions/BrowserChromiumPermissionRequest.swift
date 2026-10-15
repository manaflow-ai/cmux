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
    /// prompt bit (CEF reports it only through media access); kept outside
    /// the prompt bit range so it never collides with one.
    public static let screenCapture = Self(rawValue: 1 << 31)
}
