public import Foundation

/// A position reported to pages instead of the Mac's own location
/// (`cmux browser geolocation`).
public struct BrowserGeolocationOverride: Equatable, Sendable {
    /// Degrees north, -90...90.
    public let latitude: Double
    /// Degrees east, -180...180.
    public let longitude: Double
    /// Accuracy radius in meters, 0 or more.
    public let accuracy: Double

    /// Returns `nil` when a coordinate is out of range or not finite.
    public init?(latitude: Double, longitude: Double, accuracy: Double = 0) {
        guard latitude.isFinite, longitude.isFinite, accuracy.isFinite,
              (-90.0...90.0).contains(latitude),
              (-180.0...180.0).contains(longitude),
              accuracy >= 0 else {
            return nil
        }
        self.latitude = latitude
        self.longitude = longitude
        self.accuracy = accuracy
    }
}

/// Per-tab emulation set by browser automation: what the page sees for its
/// location and network state. The default value changes nothing.
///
/// Engine-independent: the WebKit side applies it with a page-world script
/// and a content rule list (``pageScript(dispatchesChangeEvents:)``,
/// ``BrowserWebKitEmulationController``); a Chromium tab maps the same values to
/// `Emulation.setGeolocationOverride` and `Network.emulateNetworkConditions`.
public struct BrowserEmulationOverrides: Equatable, Sendable {
    /// The reported position, or `nil` for the real one.
    public var geolocation: BrowserGeolocationOverride?
    /// Whether the page is cut off from the network.
    public var offline: Bool

    public init(geolocation: BrowserGeolocationOverride? = nil, offline: Bool = false) {
        self.geolocation = geolocation
        self.offline = offline
    }

    /// No override is active.
    public var isDefault: Bool { geolocation == nil && !offline }
}
