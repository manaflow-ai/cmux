import Foundation
import Observation

/// Persisted "default zoom" for the mobile terminal: the base font size the user
/// has chosen and can restore on demand. Shared by two entrypoints that drive the
/// same model: the zoom-control overlay's "set as default" / "restore built-in"
/// actions, and the Settings > Terminal "Terminal Font Size" stepper + reset.
///
/// The *live* zoom (``GhosttySurfaceView`` `liveFontSize`) is a transient pinch on
/// top of this base and is intentionally not persisted across launches; this is
/// the separate, explicit base the user saves. ``savedFontSize`` is `nil` when the
/// user has not chosen one, in which case the surface and a reset fall back to the
/// built-in ``MobileTerminalFontPreference/defaultSize``.
///
/// Constructed once at the app composition root and injected into the SwiftUI
/// environment (no singleton), mirroring `MobileDisplaySettings`. Settings binds
/// it with `@Bindable`; the surface reads the same injected instance so a Settings
/// change and the overlay stay in sync. The backing store is injected so tests
/// pass a scoped `UserDefaults(suiteName:)` instead of polluting `.standard`.
///
/// ```swift
/// let zoom = MobileTerminalZoomPreference()
/// zoom.save(16)          // remember 16pt as the base
/// let target = zoom.effectiveFontSize   // savedFontSize ?? defaultSize
/// ```
@MainActor
@Observable
public final class MobileTerminalZoomPreference {
    private static let savedSizeKey = "cmux.terminal.zoom.userDefaultSize.v1"

    // UserDefaults is Apple-documented thread-safe; the synchronous read in
    // `init` and the write-through in `save`/`clear` are safe nonisolated.
    private nonisolated(unsafe) let defaults: UserDefaults

    /// The user's saved base font size in points, or `nil` if none saved.
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

    /// The base size the terminal should launch at and a reset should restore:
    /// the user's saved size when set, otherwise the built-in default. Always
    /// clamped into the supported zoom range so a stale or hand-edited stored
    /// value can never push the surface outside `[minimumSize, maximumSize]`.
    public var effectiveFontSize: Float32 {
        let target = savedFontSize ?? MobileTerminalFontPreference.defaultSize
        return min(
            max(target, MobileTerminalFontPreference.minimumSize),
            MobileTerminalFontPreference.maximumSize
        )
    }

    /// Whether a non-default base size is currently saved. Drives the Settings
    /// "Reset to default" button's enabled state.
    public var hasCustomFontSize: Bool { savedFontSize != nil }

    /// Saves `size` (points, clamped to the supported range) as the user's base.
    public func save(_ size: Float32) {
        let clamped = min(
            max(size, MobileTerminalFontPreference.minimumSize),
            MobileTerminalFontPreference.maximumSize
        )
        savedFontSize = clamped
        defaults.set(clamped, forKey: Self.savedSizeKey)
    }

    /// Clears the saved base so the terminal and a reset fall back to the
    /// built-in ``MobileTerminalFontPreference/defaultSize``.
    public func clear() {
        savedFontSize = nil
        defaults.removeObject(forKey: Self.savedSizeKey)
    }

    /// Nudges the saved base by `delta` points from the current effective size,
    /// clamped to the supported range. Used by the Settings stepper, which always
    /// writes an explicit base (even when stepping from the built-in default).
    public func step(by delta: Float32) {
        save(effectiveFontSize + delta)
    }
}
