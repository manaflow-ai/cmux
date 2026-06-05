import CoreGraphics
import Foundation

/// The `window.*` policy that controls how new main windows are sized on open.
///
/// By default cmux restores the last-used window geometry. When
/// ``openAtFixedSize`` is enabled, every freshly created main window instead
/// opens at ``width`` × ``height`` points, taking precedence over both the
/// source-window match and the persisted last-window geometry. Full session
/// restore still honors each saved window's frame — see ``InitialWindowFrameSource``.
///
/// The three values map to the `window.openAtFixedSize`, `window.width`, and
/// `window.height` keys in `cmux.json` and to the matching `UserDefaults`
/// storage keys (``openAtFixedSizeStorageKey`` and friends). Read the live
/// values with ``read(from:)``:
///
/// ```swift
/// let policy = WindowOpenSizeSettings.read(from: .standard)
/// if let size = policy.fixedContentSize() {
///     // open the next window at `size`
/// }
/// ```
public struct WindowOpenSizeSettings: Equatable, Sendable {
    /// `UserDefaults` / `cmux.json` key for ``openAtFixedSize``.
    public static let openAtFixedSizeStorageKey = "window.openAtFixedSize"
    /// `UserDefaults` / `cmux.json` key for ``width``.
    public static let widthStorageKey = "window.width"
    /// `UserDefaults` / `cmux.json` key for ``height``.
    public static let heightStorageKey = "window.height"

    /// Whether new windows open at the fixed ``width`` × ``height`` size.
    public static let defaultOpenAtFixedSize = false
    /// Default fixed window width, in points (matches the built-in 1000×700 default).
    public static let defaultWidth: Double = 1_000
    /// Default fixed window height, in points (matches the built-in 1000×700 default).
    public static let defaultHeight: Double = 700
    /// Smallest accepted fixed dimension, in points.
    public static let minimumDimension: Double = 300
    /// Largest accepted fixed dimension, in points.
    public static let maximumDimension: Double = 10_000

    /// When `true`, new main windows open at ``width`` × ``height``.
    public var openAtFixedSize: Bool
    /// Configured fixed window width, in points.
    public var width: Double
    /// Configured fixed window height, in points.
    public var height: Double

    /// Creates a window-open-size policy.
    ///
    /// - Parameters:
    ///   - openAtFixedSize: Whether to open new windows at the fixed size.
    ///   - width: Fixed window width in points (clamped on use).
    ///   - height: Fixed window height in points (clamped on use).
    public init(
        openAtFixedSize: Bool = WindowOpenSizeSettings.defaultOpenAtFixedSize,
        width: Double = WindowOpenSizeSettings.defaultWidth,
        height: Double = WindowOpenSizeSettings.defaultHeight
    ) {
        self.openAtFixedSize = openAtFixedSize
        self.width = width
        self.height = height
    }

    /// Clamps a requested dimension into `[minimumDimension, maximumDimension]`.
    ///
    /// - Parameter value: The requested width or height in points.
    /// - Returns: The value clamped into the supported range.
    public static func clampDimension(_ value: Double) -> Double {
        min(max(value, minimumDimension), maximumDimension)
    }

    /// The fixed content size to open new windows at, or `nil` when disabled.
    ///
    /// Returns `nil` when ``openAtFixedSize`` is `false` so callers can fall
    /// back to the existing restore-last-size behavior. When enabled, both
    /// dimensions are clamped with ``clampDimension(_:)``.
    public func fixedContentSize() -> CGSize? {
        guard openAtFixedSize else { return nil }
        return CGSize(
            width: Self.clampDimension(width),
            height: Self.clampDimension(height)
        )
    }

    /// Reads the live `window.*` policy from a `UserDefaults` suite.
    ///
    /// Missing keys fall back to the `default*` values, so this is safe to call
    /// before any value has been written.
    ///
    /// - Parameter defaults: The suite to read from (inject a scoped suite in tests).
    /// - Returns: The resolved policy.
    public static func read(from defaults: UserDefaults) -> WindowOpenSizeSettings {
        let openAtFixedSize = (defaults.object(forKey: openAtFixedSizeStorageKey) as? NSNumber)?.boolValue
            ?? defaultOpenAtFixedSize
        let width = (defaults.object(forKey: widthStorageKey) as? NSNumber)?.doubleValue
            ?? defaultWidth
        let height = (defaults.object(forKey: heightStorageKey) as? NSNumber)?.doubleValue
            ?? defaultHeight
        return WindowOpenSizeSettings(
            openAtFixedSize: openAtFixedSize,
            width: width,
            height: height
        )
    }

    /// Resolves which geometry signal a new main window should open with.
    ///
    /// Pure precedence logic with no AppKit dependency so it can be unit-tested
    /// without launching the app. See ``InitialWindowFrameSource`` for the full
    /// precedence order.
    ///
    /// - Parameters:
    ///   - fixedContentSize: The configured fixed size, or `nil` when the fixed-size
    ///     option is off. Typically ``fixedContentSize()``.
    ///   - restoredFrame: A per-window frame from full session restore, if any.
    ///   - sourceWindowFrame: The frame of the window the new window was spawned from, if any.
    ///   - persistedGeometryFrame: The last-used window frame persisted across launches, if any.
    /// - Returns: The winning ``InitialWindowFrameSource``.
    public static func resolveInitialFrameSource(
        fixedContentSize: CGSize?,
        restoredFrame: CGRect?,
        sourceWindowFrame: CGRect?,
        persistedGeometryFrame: CGRect?
    ) -> InitialWindowFrameSource {
        if let restoredFrame {
            return .restored(restoredFrame)
        }
        // NOTE: the fixed-size branch is added in the fix commit so the
        // accompanying regression test goes red → green.
        if let sourceWindowFrame {
            return .sourceWindow(sourceWindowFrame)
        }
        if let persistedGeometryFrame {
            return .persistedGeometry(persistedGeometryFrame)
        }
        return .fallbackDefault
    }
}
