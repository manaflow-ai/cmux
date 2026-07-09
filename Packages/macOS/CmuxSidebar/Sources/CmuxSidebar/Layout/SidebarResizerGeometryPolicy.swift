public import CoreGraphics

public import CmuxSettings

/// Pure resizer geometry for the left workspace sidebar and the right file
/// explorer divider, composed from the app's fixed sidebar layout constants.
///
/// This is the composition layer that the app's `ContentView` resizer methods
/// (`minimumSidebarWidth`, `maxSidebarWidth`, `normalizedSidebarWidth`,
/// `resolvedRightSidebarAvailableWidth`, `rightSidebarConfiguredMaximumWidth`,
/// `normalizedRightSidebarWidth`) forwarded into. Each of those methods mixed a
/// live AppKit/window-geometry lookup (which window is observed, its content
/// width, the key window, the main screen) with a pure transform of the result.
/// The window lookups stay in the view; the pure transforms live here as a
/// constructor-injected value type so the math sits in one place and tests can
/// pin it.
///
/// The type holds three pieces of injected policy state: the width-clamp
/// ``SidebarWidthPolicy`` (the actual min/max clamp math for both dividers), the
/// minimum-sidebar-width sanitize bounds (the configurable left-sidebar floor),
/// and the right-sidebar width settings (the configured-maximum decode). It owns
/// no live state; the view supplies the AppKit-resolved available widths and the
/// raw setting values per call.
///
/// Extracted from `ContentView` as a faithful byte-identical lift. Behavior,
/// fallback order, and the persisted-setting decode are frozen.
public struct SidebarResizerGeometryPolicy: Sendable {
    /// The width-clamp policy for both dividers (left min/max, right min/max).
    public let widthPolicy: SidebarWidthPolicy

    /// Fallback minimum sidebar width used when a stored minimum-width setting is
    /// non-finite. Mirrors `SessionPersistencePolicy.defaultMinimumSidebarWidth`.
    public let defaultMinimumSidebarWidth: CGFloat

    /// The accepted range for the configurable minimum sidebar width. A stored
    /// minimum-width setting is clamped into this range. Mirrors
    /// `SessionPersistencePolicy.sidebarMinimumWidthRange`.
    public let minimumSidebarWidthRange: ClosedRange<CGFloat>

    /// Fallback available width used when the view cannot resolve a live window
    /// or screen width. Mirrors the terminal `1920` fallback in
    /// `ContentView.maxSidebarWidth` / `resolvedRightSidebarAvailableWidth`.
    public let fallbackAvailableWidth: CGFloat

    /// The right-sidebar width settings used to decode the configured-maximum
    /// override from its persisted value.
    public let rightSidebarWidthSettings: RightSidebarWidthSettings

    /// Creates a resizer geometry policy from the fixed sidebar layout constants.
    /// - Parameters:
    ///   - widthPolicy: The clamp policy for both dividers.
    ///   - defaultMinimumSidebarWidth: Minimum-width fallback for a non-finite
    ///     stored setting.
    ///   - minimumSidebarWidthRange: Accepted range for the configurable minimum
    ///     sidebar width.
    ///   - fallbackAvailableWidth: Available-width fallback when no live window or
    ///     screen width is resolvable.
    ///   - rightSidebarWidthSettings: The right-sidebar width settings decoder.
    public init(
        widthPolicy: SidebarWidthPolicy,
        defaultMinimumSidebarWidth: CGFloat,
        minimumSidebarWidthRange: ClosedRange<CGFloat>,
        fallbackAvailableWidth: CGFloat = 1920,
        rightSidebarWidthSettings: RightSidebarWidthSettings = RightSidebarWidthSettings()
    ) {
        self.widthPolicy = widthPolicy
        self.defaultMinimumSidebarWidth = defaultMinimumSidebarWidth
        self.minimumSidebarWidthRange = minimumSidebarWidthRange
        self.fallbackAvailableWidth = fallbackAvailableWidth
        self.rightSidebarWidthSettings = rightSidebarWidthSettings
    }

    /// Sanitizes a stored minimum-sidebar-width setting into the accepted range.
    ///
    /// A non-finite setting falls back to ``defaultMinimumSidebarWidth``; a finite
    /// setting is clamped into ``minimumSidebarWidthRange``. Mirrors
    /// `SessionPersistencePolicy.sanitizedMinimumSidebarWidth`.
    /// - Parameter setting: The persisted minimum-width setting value.
    /// - Returns: The sanitized minimum sidebar width.
    public func minimumSidebarWidth(setting: CGFloat) -> CGFloat {
        guard setting.isFinite else { return defaultMinimumSidebarWidth }
        return min(
            max(setting, minimumSidebarWidthRange.lowerBound),
            minimumSidebarWidthRange.upperBound
        )
    }

    /// The window-derived maximum left-sidebar width.
    ///
    /// When the view resolves a positive content/window width it is used directly;
    /// otherwise the view's resolved screen width (or ``fallbackAvailableWidth``)
    /// is used. Both feed ``SidebarWidthPolicy/maximumLeftSidebarWidth(availableWidth:minimumWidth:)``.
    /// Mirrors `ContentView.maxSidebarWidth(availableWidth:)`.
    /// - Parameters:
    ///   - resolvedAvailableWidth: The content/window width the view resolved from
    ///     live AppKit geometry, or `nil` when unavailable.
    ///   - fallbackScreenWidth: The screen width the view resolved as a fallback,
    ///     or `nil` to use ``fallbackAvailableWidth``.
    ///   - minimumWidth: The configured minimum sidebar width (hard floor).
    /// - Returns: The maximum left-sidebar width.
    public func maxSidebarWidth(
        resolvedAvailableWidth: CGFloat?,
        fallbackScreenWidth: CGFloat?,
        minimumWidth: CGFloat
    ) -> CGFloat {
        if let resolvedAvailableWidth, resolvedAvailableWidth > 0 {
            return widthPolicy.maximumLeftSidebarWidth(
                availableWidth: resolvedAvailableWidth,
                minimumWidth: minimumWidth
            )
        }
        return widthPolicy.maximumLeftSidebarWidth(
            availableWidth: fallbackScreenWidth ?? fallbackAvailableWidth,
            minimumWidth: minimumWidth
        )
    }

    /// Clamps a candidate left-sidebar width to the given max/min.
    ///
    /// Mirrors `ContentView.normalizedSidebarWidth` /
    /// `ContentView.clampedSidebarWidth`.
    /// - Parameters:
    ///   - candidate: The proposed left-sidebar width.
    ///   - maximumWidth: The window-derived maximum width.
    ///   - minimumWidth: The configured minimum sidebar width.
    /// - Returns: The clamped width.
    public func normalizedSidebarWidth(
        _ candidate: CGFloat,
        maximumWidth: CGFloat,
        minimumWidth: CGFloat
    ) -> CGFloat {
        widthPolicy.clampLeftSidebarWidth(
            candidate,
            maximumWidth: maximumWidth,
            minimumWidth: minimumWidth
        )
    }

    /// Resolves the available content width for the right file explorer clamp.
    ///
    /// Returns the first non-`nil` value from the view's resolved live geometry
    /// chain (observed content width, observed layout width, key-window content
    /// width, key-window layout width, key-window screen width, main-screen
    /// width), falling back to ``fallbackAvailableWidth`` when the view resolves
    /// nothing. Mirrors `ContentView.resolvedRightSidebarAvailableWidth`.
    /// - Parameter resolvedWidths: The view's ordered live geometry candidates,
    ///   already gathered from AppKit; the first non-`nil` entry wins.
    /// - Returns: The available content width to clamp against.
    public func resolvedRightSidebarAvailableWidth(
        resolvedWidths: [CGFloat?]
    ) -> CGFloat {
        for width in resolvedWidths {
            if let width {
                return width
            }
        }
        return fallbackAvailableWidth
    }

    /// Decodes the configured right-sidebar maximum width from its persisted
    /// setting value.
    ///
    /// Returns `nil` when the override is inactive (the built-in dynamic cap is
    /// used). Mirrors `ContentView.rightSidebarConfiguredMaximumWidth`.
    /// - Parameter setting: The persisted right-sidebar max-width setting value.
    /// - Returns: The configured maximum width, or `nil` when no override.
    public func rightSidebarConfiguredMaximumWidth(setting: Double) -> CGFloat? {
        guard let width = rightSidebarWidthSettings.configuredMaximumWidth(from: setting) else {
            return nil
        }
        return CGFloat(width)
    }

    /// Clamps a candidate right file-explorer width against the resolved
    /// available width and an optional configured maximum.
    ///
    /// Mirrors `ContentView.normalizedRightSidebarWidth` /
    /// `ContentView.clampedRightSidebarWidth`.
    /// - Parameters:
    ///   - candidate: The proposed explorer width.
    ///   - availableWidth: The resolved available content width.
    ///   - configuredMaximumWidth: An optional user-configured maximum.
    /// - Returns: The clamped width.
    public func normalizedRightSidebarWidth(
        _ candidate: CGFloat,
        availableWidth: CGFloat,
        configuredMaximumWidth: CGFloat?
    ) -> CGFloat {
        widthPolicy.clampRightSidebarWidth(
            candidate,
            availableWidth: availableWidth,
            configuredMaximumWidth: configuredMaximumWidth
        )
    }
}
