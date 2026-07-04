public import CoreGraphics
public import Foundation

/// Stores and normalizes the browser page zoom preference.
///
/// Use this value from browser surfaces that need a persisted last-used page
/// zoom. The caller supplies the `UserDefaults` instance so tests can isolate
/// storage without touching `UserDefaults.standard`.
public struct BrowserPageZoomPreference {
    /// The `UserDefaults` key that stores the last-used page zoom.
    public static let storageKey = "browserLastPageZoom"

    /// The zoom used when no valid persisted value exists.
    public static let defaultZoom: CGFloat = 1.0

    /// The lowest page zoom accepted by cmux browser surfaces.
    public static let minimumZoom: CGFloat = 0.25

    /// The highest page zoom accepted by cmux browser surfaces.
    public static let maximumZoom: CGFloat = 5.0

    private let defaults: UserDefaults

    /// Creates a preference wrapper backed by the supplied defaults store.
    ///
    /// - Parameter defaults: The defaults store to read and write. Defaults to
    ///   `UserDefaults.standard` for production browser panels.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Returns the current persisted zoom, clamped into the supported range.
    public func currentZoom() -> CGFloat {
        guard let rawValue = defaults.object(forKey: Self.storageKey) else {
            return Self.defaultZoom
        }
        guard let number = rawValue as? NSNumber else {
            return Self.defaultZoom
        }
        return clampedZoom(CGFloat(number.doubleValue))
    }

    /// Rewrites an existing stored zoom when it is invalid or out of range.
    ///
    /// - Returns: The normalized zoom value that should be used by a browser
    ///   panel.
    @discardableResult
    public func normalizeStoredZoom() -> CGFloat {
        guard let rawValue = defaults.object(forKey: Self.storageKey) else {
            return Self.defaultZoom
        }
        let zoom = currentZoom()
        guard let number = rawValue as? NSNumber else {
            defaults.set(Double(zoom), forKey: Self.storageKey)
            return zoom
        }
        let rawZoom = CGFloat(number.doubleValue)
        if !rawZoom.isFinite || abs(rawZoom - zoom) >= 0.0001 {
            defaults.set(Double(zoom), forKey: Self.storageKey)
        }
        return zoom
    }

    /// Persists a supported zoom value.
    ///
    /// - Parameter zoom: The candidate zoom to clamp and store.
    public func save(_ zoom: CGFloat) {
        defaults.set(Double(clampedZoom(zoom)), forKey: Self.storageKey)
    }

    /// Clamps a candidate zoom into the browser-supported range.
    ///
    /// - Parameter zoom: The candidate zoom to validate.
    /// - Returns: `defaultZoom` for non-finite input, otherwise the nearest
    ///   supported zoom value.
    public func clampedZoom(_ zoom: CGFloat) -> CGFloat {
        guard zoom.isFinite else { return Self.defaultZoom }
        return max(Self.minimumZoom, min(Self.maximumZoom, zoom))
    }
}
