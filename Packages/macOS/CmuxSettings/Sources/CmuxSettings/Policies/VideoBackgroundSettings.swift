import Foundation

/// Shared policy for the dynamic video background drawn behind terminal
/// content.
///
/// The feature is opt-in: a muted, non-interactive video layer (a YouTube
/// video/playlist embed, or a looping local file) is composited behind the
/// window's terminal backdrop, and the regular terminal background fill is
/// redrawn over it at ``dimOpacity(defaults:)`` so text stays readable. The
/// optional queue, quality cap, and volume use the same keys across Settings,
/// `cmux.json`, and the CLI.
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

    /// UserDefaults key backing the ordered `terminal.videoBackground.queue`
    /// setting. Each entry is a YouTube URL/ID or a local video-file path.
    public static let queueKey = "terminal.videoBackground.queue"

    /// UserDefaults key backing the YouTube stream quality cap.
    public static let qualityKey = "terminal.videoBackground.quality"

    /// UserDefaults key backing the video volume (`0...1`).
    public static let volumeKey = "terminal.videoBackground.volume"

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

    /// Default YouTube quality cap. The 1080p-sized embed is a useful balance
    /// between sharpness and GPU/network cost on Retina displays.
    public static let defaultQuality = "1080p"

    /// Default volume when audio is explicitly enabled.
    public static let defaultVolume: Double = 1.0

    /// Quality values accepted by the settings UI, cmux.json, and CLI.
    public static let qualityOptions = ["720p", "1080p", "1440p", "2160p"]

    /// Maximum number of queued entries accepted from configuration files.
    /// Bounding this list keeps a malformed or generated config from creating
    /// an unbounded number of WebKit/AVFoundation replacements.
    public static let maximumQueueLength = 128

    /// Fully transparent overlay: the video shows through undimmed.
    public static let minimumDimOpacity: Double = 0.0

    /// Fully opaque overlay: the video is completely hidden.
    public static let maximumDimOpacity: Double = 1.0

    /// Step used by the settings UI dim slider.
    public static let dimOpacityStep: Double = 0.05

    /// Step used by the settings UI volume slider.
    public static let volumeStep: Double = 0.05

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

    /// Reads the ordered queue from a UserDefaults suite, trimming whitespace
    /// and dropping empty entries. A missing queue returns an empty array so
    /// the legacy single ``sourceKey`` remains the fallback.
    public func queue(defaults: UserDefaults) -> [String] {
        normalizedQueue(defaults.array(forKey: Self.queueKey) as? [String] ?? [])
    }

    /// Returns a bounded, trimmed queue suitable for persistence or playback.
    public func normalizedQueue(_ values: [String]) -> [String] {
        Array(
            values
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .prefix(Self.maximumQueueLength)
        )
    }

    /// Returns queue entries, falling back to the original single-source key
    /// for configurations written before queue support existed.
    public func effectiveSourceTexts(defaults: UserDefaults) -> [String] {
        let queued = queue(defaults: defaults)
        if !queued.isEmpty { return queued }
        let source = sourceText(defaults: defaults).trimmingCharacters(in: .whitespacesAndNewlines)
        return source.isEmpty ? [] : [source]
    }

    /// Reads and normalizes the configured quality cap.
    public func quality(defaults: UserDefaults) -> String {
        normalizedQuality(defaults.string(forKey: Self.qualityKey))
    }

    /// Reads and clamps the configured volume.
    public func volume(defaults: UserDefaults) -> Double {
        normalizedVolume(Double.decodeFromUserDefaults(defaults.object(forKey: Self.volumeKey)))
    }

    /// Returns a finite volume bounded to `0...1`; missing/non-finite values
    /// use the full-volume default.
    public func normalizedVolume(_ rawValue: Double?) -> Double {
        guard let rawValue, rawValue.isFinite else { return Self.defaultVolume }
        return min(max(rawValue, 0), 1)
    }

    /// Normalizes aliases and unknown quality values to the safe default.
    public func normalizedQuality(_ rawValue: String?) -> String {
        let normalized = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "720", "720p": return "720p"
        case "1080", "1080p", "auto", "": return "1080p"
        case "1440", "1440p", "2k": return "1440p"
        case "2160", "2160p", "4k", "uhd": return "2160p"
        default: return Self.defaultQuality
        }
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
