/// A permission in serve-sim's Apache-2.0 permission catalog.
///
/// Public `simctl privacy` services execute directly. Values backed by private
/// TCC or BulletinBoard stores remain typed so callers get an explicit
/// unsupported error when the active Xcode offers no contained adapter.
public enum SimulatorPrivacyService: String, Codable, CaseIterable, Hashable, Sendable {
    /// Every privacy service.
    case all
    /// Calendar events.
    case calendar
    /// Limited contact details.
    case contactsLimited = "contacts-limited"
    /// Full contact details.
    case contacts
    /// Foreground location.
    case location
    /// Background and foreground location.
    case locationAlways = "location-always"
    /// Foreground-only location, named explicitly for tools parity.
    case locationInUse = "location-inuse"
    /// Adding items to Photos.
    case photosAdd = "photos-add"
    /// Full Photos access.
    case photos
    /// Limited Photos library access.
    case photosLimited = "photos-limited"
    /// Media-library access.
    case mediaLibrary = "media-library"
    /// Audio input.
    case microphone
    /// Motion and fitness data.
    case motion
    /// Reminders.
    case reminders
    /// Siri integration.
    case siri
    /// Camera input through the isolated private-permissions adapter.
    case camera
    /// Push-notification authorization.
    case notifications
    /// Push notifications including critical alerts.
    case criticalNotifications = "notifications-critical"
    /// Speech recognition.
    case speech
    /// Face ID authentication.
    case faceID = "faceid"
    /// App Tracking Transparency.
    case userTracking = "user-tracking"
    /// HomeKit data.
    case homeKit = "homekit"

    /// Whether this permission requires the isolated, version-gated worker
    /// adapter instead of public `simctl privacy`.
    public var requiresIsolatedMutation: Bool {
        switch self {
        case .photosLimited, .camera, .notifications, .criticalNotifications, .speech,
             .faceID, .userTracking, .homeKit:
            true
        default:
            false
        }
    }
}
