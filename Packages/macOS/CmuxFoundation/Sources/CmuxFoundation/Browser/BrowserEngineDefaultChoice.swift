import Foundation

/// Persisted preference for the engine used by newly created browser panes.
///
/// The preference is one level above ``BrowserEngineKind``: a pane always runs
/// a concrete engine, while the preference may also be `.auto`, which follows
/// the user's system default browser at pane-creation time.
public enum BrowserEngineDefaultChoice: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    /// Match the system default browser: Chromium-family browsers select the
    /// managed Chromium engine, everything else selects WebKit.
    case auto

    /// Always use the built-in `WKWebView` engine.
    case webkit

    /// Always use the managed out-of-process Chromium engine.
    case chromium

    /// Stable settings identifier.
    public var id: String { rawValue }

    /// The shipped default: follow the system default browser.
    public static let `default`: BrowserEngineDefaultChoice = .auto

    /// Decodes a persisted preference spelling with compatibility aliases.
    ///
    /// Explicit engine choices persisted by earlier builds are preserved;
    /// anything unrecognized falls back to the shipped `.auto` behavior.
    ///
    /// - Parameter persistedRawValue: Persisted preference spelling.
    public init(persistedRawValue: String) {
        switch persistedRawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "webkit", "safari":
            self = .webkit
        case "chromium", "chrome", "headless-shell":
            self = .chromium
        default:
            self = .auto
        }
    }

    /// Resolves the concrete engine for a new pane.
    ///
    /// - Parameter systemDefaultBrowserIsChromium: Whether the user's default
    ///   browser is a Chromium-family browser. Evaluated only for `.auto`.
    /// - Returns: The engine a new pane should run.
    public func resolvedEngine(
        systemDefaultBrowserIsChromium: @autoclosure () -> Bool
    ) -> BrowserEngineKind {
        switch self {
        case .webkit:
            return .webkit
        case .chromium:
            return .chromium
        case .auto:
            return systemDefaultBrowserIsChromium() ? .chromium : .webkit
        }
    }

    /// Reports whether a default-browser bundle identifier belongs to a
    /// Chromium-family browser.
    ///
    /// The list is a conservative allowlist of well-known Blink browsers;
    /// unknown identifiers resolve to WebKit under `.auto`.
    ///
    /// - Parameter bundleIdentifier: The default HTTP handler's bundle identifier.
    /// - Returns: `true` when the browser is Chromium-based.
    public static func isChromiumFamilyBundleIdentifier(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        let normalized = bundleIdentifier.lowercased()
        let chromiumFamilyPrefixes = [
            "com.google.chrome",
            "org.chromium.chromium",
            "com.microsoft.edgemac",
            "com.brave.browser",
            "com.vivaldi.vivaldi",
            "com.operasoftware.opera",
            "company.thebrowser.browser",
            "company.thebrowser.dia",
            "ru.yandex.desktop.yandex-browser",
        ]
        return chromiumFamilyPrefixes.contains { normalized.hasPrefix($0) }
    }

    /// Decodes persisted preference values with fail-open-to-auto compatibility.
    ///
    /// - Parameter decoder: Decoder containing one preference string.
    /// - Throws: An error when the payload is not a string.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(persistedRawValue: try container.decode(String.self))
    }

    /// Encodes the canonical spelling used by settings.
    ///
    /// - Parameter encoder: Encoder that receives the canonical raw value.
    /// - Throws: An error when the encoder cannot accept the string.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
