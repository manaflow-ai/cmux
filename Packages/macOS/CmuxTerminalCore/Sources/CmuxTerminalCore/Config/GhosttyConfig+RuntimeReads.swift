public import AppKit
public import CmuxFoundation
public import GhosttyKit

// Reads of the live `ghostty_config_t` handle that GhosttyConfig owns the
// vocabulary for. These are pure functions of a parsed ghostty config: they
// call `ghostty_config_get` and translate the C result into cmux value types
// (colors, scrollbar visibility, bell directives, the resolved default-background
// bundle). They perform no mutation of the handle and hold no state, so they
// live as static members on the config value type the results belong to rather
// than on the app-target engine that happens to hold the handle.
extension GhosttyConfig {
    /// Whether ghostty's `scrollbar` directive requests the native scrollbar
    /// (`system`) or suppresses it (`never`).
    public enum ScrollbarVisibility: String, Sendable {
        case system
        case never
    }

    /// The resolved default-appearance colors and background metrics read from a
    /// `ghostty_config_t` (or the baseline fallback when no handle is present).
    public struct DefaultBackgroundValues: Sendable {
        public var backgroundColor: NSColor
        public var backgroundOpacity: Double
        public var backgroundBlur: GhosttyBackgroundBlur
        public var foregroundColor: NSColor
        public var cursorColor: NSColor
        public var cursorTextColor: NSColor
        public var selectionBackground: NSColor
        public var selectionForeground: NSColor

        public init(
            backgroundColor: NSColor,
            backgroundOpacity: Double,
            backgroundBlur: GhosttyBackgroundBlur,
            foregroundColor: NSColor,
            cursorColor: NSColor,
            cursorTextColor: NSColor,
            selectionBackground: NSColor,
            selectionForeground: NSColor
        ) {
            self.backgroundColor = backgroundColor
            self.backgroundOpacity = backgroundOpacity
            self.backgroundBlur = backgroundBlur
            self.foregroundColor = foregroundColor
            self.cursorColor = cursorColor
            self.cursorTextColor = cursorTextColor
            self.selectionBackground = selectionBackground
            self.selectionForeground = selectionForeground
        }
    }

    /// Reads a single ghostty color directive (`key`) from `config`, returning
    /// `fallback` when the directive is absent.
    public static func colorValue(
        from config: ghostty_config_t,
        key: String,
        fallback: NSColor
    ) -> NSColor {
        var color = ghostty_config_color_s()
        guard ghostty_config_get(config, &color, key, UInt(key.lengthOfBytes(using: .utf8))) else {
            return fallback
        }
        return NSColor(
            red: CGFloat(color.r) / 255,
            green: CGFloat(color.g) / 255,
            blue: CGFloat(color.b) / 255,
            alpha: 1.0
        )
    }

    /// Reads the `background-blur` directive from `config`, returning
    /// ``GhosttyBackgroundBlur/disabled`` when the directive is absent.
    public static func backgroundBlurValue(from config: ghostty_config_t) -> GhosttyBackgroundBlur {
        var value: Int16 = 0
        let key = "background-blur"
        guard ghostty_config_get(config, &value, key, UInt(key.lengthOfBytes(using: .utf8))) else {
            return .disabled
        }
        return GhosttyBackgroundBlur(cValue: value)
    }

    /// Resolves the full default-appearance color bundle from `config`, falling
    /// back to `baseline`'s values directive-by-directive. When `config` is `nil`,
    /// every value comes from `baseline`.
    public static func defaultBackgroundValues(
        from config: ghostty_config_t?,
        baseline: GhosttyConfig
    ) -> DefaultBackgroundValues {
        guard let config else {
            return DefaultBackgroundValues(
                backgroundColor: baseline.backgroundColor,
                backgroundOpacity: baseline.backgroundOpacity,
                backgroundBlur: baseline.backgroundBlur,
                foregroundColor: baseline.foregroundColor,
                cursorColor: baseline.cursorColor,
                cursorTextColor: baseline.cursorTextColor,
                selectionBackground: baseline.selectionBackground,
                selectionForeground: baseline.selectionForeground
            )
        }

        let resolvedColor = colorValue(from: config, key: "background", fallback: baseline.backgroundColor)
        let resolvedForeground = colorValue(from: config, key: "foreground", fallback: baseline.foregroundColor)
        let resolvedCursor = colorValue(from: config, key: "cursor-color", fallback: baseline.cursorColor)
        let resolvedCursorText = colorValue(from: config, key: "cursor-text", fallback: baseline.cursorTextColor)
        let resolvedSelectionBackground = colorValue(from: config, key: "selection-background", fallback: baseline.selectionBackground)
        let resolvedSelectionForeground = colorValue(from: config, key: "selection-foreground", fallback: baseline.selectionForeground)
        var opacity = baseline.backgroundOpacity
        let opacityKey = "background-opacity"
        _ = ghostty_config_get(config, &opacity, opacityKey, UInt(opacityKey.lengthOfBytes(using: .utf8)))
        opacity = min(1.0, max(0.0, opacity))
        let backgroundBlur = backgroundBlurValue(from: config)
        return DefaultBackgroundValues(
            backgroundColor: resolvedColor,
            backgroundOpacity: opacity,
            backgroundBlur: backgroundBlur,
            foregroundColor: resolvedForeground,
            cursorColor: resolvedCursor,
            cursorTextColor: resolvedCursorText,
            selectionBackground: resolvedSelectionBackground,
            selectionForeground: resolvedSelectionForeground
        )
    }

    /// Picks between the parsed directive value, the legacy baseline value, and
    /// the unspecified fallback when folding a resolved on-disk config back onto
    /// a baseline. Mirrors the three-way precedence the engine applies per
    /// appearance directive.
    public static func resolvedAppearanceValue<T>(
        parsedValue: T,
        baselineValue: T,
        unspecifiedFallbackValue: T,
        hasParsedDirective: Bool,
        hasDirective: Bool
    ) -> T {
        if hasParsedDirective {
            return parsedValue
        }
        if hasDirective {
            return baselineValue
        }
        return unspecifiedFallbackValue
    }

    /// Folds a freshly parsed on-disk `resolved` config back onto the legacy
    /// `baseline` bundle, applying ``resolvedAppearanceValue(parsedValue:baselineValue:unspecifiedFallbackValue:hasParsedDirective:hasDirective:)``
    /// per appearance directive. `fallbackForUnspecified` supplies each value
    /// when neither the parsed config nor the baseline declared the directive.
    public static func resolvedDefaultBackgroundValues(
        resolved: GhosttyConfig,
        baseline: DefaultBackgroundValues,
        fallbackForUnspecified: DefaultBackgroundValues
    ) -> DefaultBackgroundValues {
        DefaultBackgroundValues(
            backgroundColor: resolvedAppearanceValue(
                parsedValue: resolved.backgroundColor,
                baselineValue: baseline.backgroundColor,
                unspecifiedFallbackValue: fallbackForUnspecified.backgroundColor,
                hasParsedDirective: resolved.hasParsedBackgroundColor,
                hasDirective: resolved.hasBackgroundColorDirective
            ),
            backgroundOpacity: resolvedAppearanceValue(
                parsedValue: resolved.backgroundOpacity,
                baselineValue: baseline.backgroundOpacity,
                unspecifiedFallbackValue: fallbackForUnspecified.backgroundOpacity,
                hasParsedDirective: resolved.hasParsedBackgroundOpacity,
                hasDirective: resolved.hasBackgroundOpacityDirective
            ),
            backgroundBlur: resolvedAppearanceValue(
                parsedValue: resolved.backgroundBlur,
                baselineValue: baseline.backgroundBlur,
                unspecifiedFallbackValue: fallbackForUnspecified.backgroundBlur,
                hasParsedDirective: resolved.hasParsedBackgroundBlur,
                hasDirective: resolved.hasBackgroundBlurDirective
            ),
            foregroundColor: resolvedAppearanceValue(
                parsedValue: resolved.foregroundColor,
                baselineValue: baseline.foregroundColor,
                unspecifiedFallbackValue: fallbackForUnspecified.foregroundColor,
                hasParsedDirective: resolved.hasParsedForegroundColor,
                hasDirective: resolved.hasForegroundColorDirective
            ),
            cursorColor: resolvedAppearanceValue(
                parsedValue: resolved.cursorColor,
                baselineValue: baseline.cursorColor,
                unspecifiedFallbackValue: fallbackForUnspecified.cursorColor,
                hasParsedDirective: resolved.hasParsedCursorColor,
                hasDirective: resolved.hasCursorColorDirective
            ),
            cursorTextColor: resolvedAppearanceValue(
                parsedValue: resolved.cursorTextColor,
                baselineValue: baseline.cursorTextColor,
                unspecifiedFallbackValue: fallbackForUnspecified.cursorTextColor,
                hasParsedDirective: resolved.hasParsedCursorTextColor,
                hasDirective: resolved.hasCursorTextColorDirective
            ),
            selectionBackground: resolvedAppearanceValue(
                parsedValue: resolved.selectionBackground,
                baselineValue: baseline.selectionBackground,
                unspecifiedFallbackValue: fallbackForUnspecified.selectionBackground,
                hasParsedDirective: resolved.hasParsedSelectionBackground,
                hasDirective: resolved.hasSelectionBackgroundDirective
            ),
            selectionForeground: resolvedAppearanceValue(
                parsedValue: resolved.selectionForeground,
                baselineValue: baseline.selectionForeground,
                unspecifiedFallbackValue: fallbackForUnspecified.selectionForeground,
                hasParsedDirective: resolved.hasParsedSelectionForeground,
                hasDirective: resolved.hasSelectionForegroundDirective
            )
        )
    }

    /// Whether ghostty's `focus-follows-mouse` directive is enabled in `config`.
    public static func focusFollowsMouseEnabled(in config: ghostty_config_t?) -> Bool {
        guard let config else { return false }
        var enabled = false
        let key = "focus-follows-mouse"
        let keyLength = UInt(key.lengthOfBytes(using: .utf8))
        let found = ghostty_config_get(config, &enabled, key, keyLength)
        return found && enabled
    }

    /// The `scrollbar` directive in `config`, defaulting to ``ScrollbarVisibility/system``.
    public static func scrollbarVisibility(in config: ghostty_config_t?) -> ScrollbarVisibility {
        guard let config else { return .system }
        var value: UnsafePointer<Int8>?
        let key = "scrollbar"
        guard ghostty_config_get(config, &value, key, UInt(key.lengthOfBytes(using: .utf8))),
              let value else {
            return .system
        }
        return ScrollbarVisibility(rawValue: String(cString: value)) ?? .system
    }

    /// Whether ghostty's `macos-applescript` directive is enabled in `config`.
    public static func appleScriptAutomationEnabled(in config: ghostty_config_t?) -> Bool {
        guard let config else { return false }
        var enabled = false
        let key = "macos-applescript"
        _ = ghostty_config_get(config, &enabled, key, UInt(key.lengthOfBytes(using: .utf8)))
        return enabled
    }

    /// The `bell-features` directive bitfield in `config`.
    public static func bellFeatures(in config: ghostty_config_t?) -> CUnsignedInt {
        guard let config else { return 0 }
        var features: CUnsignedInt = 0
        let key = "bell-features"
        _ = ghostty_config_get(config, &features, key, UInt(key.lengthOfBytes(using: .utf8)))
        return features
    }

    /// The `bell-audio-path` directive in `config`, or `nil` when empty/absent.
    public static func bellAudioPath(in config: ghostty_config_t?) -> String? {
        guard let config else { return nil }
        var value: UnsafePointer<Int8>?
        let key = "bell-audio-path"
        guard ghostty_config_get(config, &value, key, UInt(key.lengthOfBytes(using: .utf8))),
              let rawPath = value else {
            return nil
        }
        let path = String(cString: rawPath)
        return path.isEmpty ? nil : path
    }

    /// The `bell-audio-volume` directive in `config`, clamped to `0...1`,
    /// defaulting to `0.5`.
    public static func bellAudioVolume(in config: ghostty_config_t?) -> Float {
        guard let config else { return 0.5 }
        var value: Double = 0.5
        let key = "bell-audio-volume"
        _ = ghostty_config_get(config, &value, key, UInt(key.lengthOfBytes(using: .utf8)))
        return Float(min(1.0, max(0.0, value)))
    }
}
