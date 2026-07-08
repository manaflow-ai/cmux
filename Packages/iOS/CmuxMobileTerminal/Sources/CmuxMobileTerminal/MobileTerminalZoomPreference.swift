import Foundation

/// Persisted "default zoom" for the mobile terminal: the font size the user has
/// chosen as their baseline and can restore on demand from the zoom-control
/// overlay.
///
/// The *live* zoom (``GhosttySurfaceView`` `liveFontSize`) is intentionally not
/// persisted across launches; this is the separate, explicit default the user
/// saves with the overlay's "Set as default" action. ``savedFontSize`` is `nil`
/// when the user has not saved one, in which case a reset falls back to the
/// built-in ``MobileTerminalFontPreference/defaultSize``.
///
/// ```swift
/// let zoom = MobileTerminalZoomPreference()
/// zoom.save(16)          // remember 16pt as the default
/// let target = zoom.savedFontSize ?? MobileTerminalFontPreference.defaultSize
/// ```
@MainActor
public final class MobileTerminalZoomPreference {
    private static let savedSizeKey = "cmux.terminal.zoom.userDefaultSize.v1"

    private let defaults: UserDefaults

    /// The user's saved default font size in points, or `nil` if none saved.
    public private(set) var savedFontSize: Float32?

    /// Creates a preference store.
    ///
    /// - Parameter defaults: The backing store. Tests pass a
    ///   `UserDefaults(suiteName:)` so they never touch the developer's
    ///   settings; production uses `.standard`.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Self.savedSizeKey) != nil {
            let raw = defaults.float(forKey: Self.savedSizeKey)
            savedFontSize = raw > 0 ? raw : nil
        } else {
            savedFontSize = nil
        }
    }

    /// Saves `size` (points) as the user's default zoom.
    public func save(_ size: Float32) {
        savedFontSize = size
        defaults.set(size, forKey: Self.savedSizeKey)
    }

    /// Clears the saved default zoom so a reset falls back to the built-in size.
    public func clear() {
        savedFontSize = nil
        defaults.removeObject(forKey: Self.savedSizeKey)
    }
}
