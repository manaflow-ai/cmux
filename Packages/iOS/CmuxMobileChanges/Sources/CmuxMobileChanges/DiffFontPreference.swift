public import Foundation

/// A small injected `UserDefaults` store for the diff viewer's monospaced font size.
@MainActor
public final class DiffFontPreference {
    /// Smallest supported diff font size in points.
    public static let minimumPointSize = 9.0
    /// Largest supported diff font size in points.
    public static let maximumPointSize = 22.0
    /// Default diff font size in points.
    public static let defaultPointSize = 12.0

    private let defaults: UserDefaults
    private let key: String

    /// Creates a font preference store.
    /// - Parameters:
    ///   - defaults: Defaults database to read and write.
    ///   - key: Storage key, injectable for tests and embedding clients.
    public init(
        defaults: UserDefaults,
        key: String = "cmux.mobile.changes.diffFontPointSize"
    ) {
        self.defaults = defaults
        self.key = key
    }

    /// Persisted point size, clamped to the supported 9...22 range.
    public var pointSize: Double {
        get {
            guard let number = defaults.object(forKey: key) as? NSNumber else {
                return Self.defaultPointSize
            }
            return Self.clamped(number.doubleValue)
        }
        set {
            defaults.set(Self.clamped(newValue), forKey: key)
        }
    }

    private static func clamped(_ pointSize: Double) -> Double {
        guard pointSize.isFinite else { return defaultPointSize }
        return min(max(pointSize, minimumPointSize), maximumPointSize)
    }
}
