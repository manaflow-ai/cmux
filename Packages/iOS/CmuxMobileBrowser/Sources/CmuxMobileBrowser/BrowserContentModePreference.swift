/// The browser content mode used for subsequent page loads.
public enum BrowserContentModePreference: Equatable, Sendable {
    /// Follow WebKit's recommended mode for the device.
    case recommended
    /// Force the mobile site.
    case mobile
    /// Force the desktop site.
    case desktop
}
