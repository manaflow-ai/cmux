import Foundation

/// Shared policy for the dynamic video background drawn behind terminal
/// content.
///
/// The feature is opt-in: a muted, non-interactive video layer (a YouTube
/// video/playlist embed, or a looping local file) is composited behind the
/// window's terminal backdrop, and the regular terminal background fill is
/// redrawn over it at ``dimOpacity(defaults:)`` so text stays readable.
/// Keeping the keys, defaults, and normalization here means UserDefaults,
/// cmux.json, the settings UI, and the runtime window layer agree on the
/// same values.
public struct VideoBackgroundSettings: Sendable {
    /// Creates a stateless video background policy value.
    public init() {}

    /// UserDefaults key backing the `terminal.videoBackground.enabled` setting.
    public static let enabledKey = "terminal.videoBackground.enabled"

    /// UserDefaults key backing the `terminal.videoBackground.source` setting.
    public static let sourceKey = "terminal.videoBackground.source"

    /// UserDefaults key backing the `terminal.videoBackground.dimOpacity` setting.
    public static let dimOpacityKey = "terminal.videoBackground.dimOpacity"

    /// UserDefaults key backing the `terminal.videoBackground.muted` setting.
    public static let mutedKey = "terminal.videoBackground.muted"

    /// The feature ships off; a source must be configured explicitly.
    public static let defaultEnabled = false

    /// Default source text (no video configured).
    public static let defaultSource = ""

    /// The video ships silent; audio is an explicit opt-in.
    public static let defaultMuted = true

    /// Default opacity of the terminal background fill drawn over the video.
    ///
    /// High enough that terminal text stays comfortably readable out of the
    /// box; the slider lets the user trade legibility for video visibility.
    public static let defaultDimOpacity: Double = 0.8

    /// Fully transparent overlay: the video shows through undimmed.
    public static let minimumDimOpacity: Double = 0.0

    /// Fully opaque overlay: the video is completely hidden.
    public static let maximumDimOpacity: Double = 1.0

    /// Step used by the settings UI dim slider.
    public static let dimOpacityStep: Double = 0.05

    /// Returns a finite dim opacity bounded to `0...1`.
    /// Non-finite or absent values use the default.
    public func normalizedDimOpacity(_ rawValue: Double?) -> Double {
        guard let rawValue, rawValue.isFinite else { return Self.defaultDimOpacity }
        return min(max(rawValue, Self.minimumDimOpacity), Self.maximumDimOpacity)
    }

    /// Reads whether the video background is enabled from a UserDefaults suite.
    public func isEnabled(defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: Self.enabledKey) != nil else { return Self.defaultEnabled }
        return defaults.bool(forKey: Self.enabledKey)
    }

    /// Reads whether the video background must stay silent from a UserDefaults suite.
    ///
    /// Even when `false`, only one window (the most recently active one) plays
    /// audio, and audio always stops with the video.
    public func isMuted(defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: Self.mutedKey) != nil else { return Self.defaultMuted }
        return defaults.bool(forKey: Self.mutedKey)
    }

    /// Reads the raw configured source text (URL or ID) from a UserDefaults suite.
    public func sourceText(defaults: UserDefaults) -> String {
        defaults.string(forKey: Self.sourceKey) ?? Self.defaultSource
    }

    /// Reads and normalizes the configured dim opacity from a UserDefaults suite.
    ///
    /// - Parameter defaults: The settings suite that owns the video background keys.
    /// - Returns: The configured finite opacity, clamped to `0...1`.
    public func dimOpacity(defaults: UserDefaults) -> Double {
        normalizedDimOpacity(Double.decodeFromUserDefaults(defaults.object(forKey: Self.dimOpacityKey)))
    }
}
