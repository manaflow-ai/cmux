import Foundation

/// Rendering and automation engine selected for one browser pane.
///
/// The value lives in the dependency-neutral foundation package so Settings,
/// control-socket inputs, session persistence, and renderer adapters share one
/// exhaustive source of truth. WebKit remains the fail-closed default.
public enum BrowserEngineKind: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    /// The built-in `WKWebView` engine.
    case webkit

    /// A managed out-of-process Chromium engine.
    case chromium

    /// Stable settings and session identifier.
    public var id: String { rawValue }

    /// The fail-closed engine used when no explicit selection exists.
    public static let `default`: BrowserEngineKind = .webkit

    /// Decodes a persisted engine spelling with compatibility aliases.
    ///
    /// Unknown values fail closed to WebKit so a snapshot written by a newer
    /// cmux version cannot unexpectedly launch an external renderer.
    ///
    /// - Parameter persistedRawValue: Persisted engine spelling.
    public init(persistedRawValue: String) {
        switch persistedRawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "chromium", "chrome", "headless-shell":
            self = .chromium
        default:
            self = .webkit
        }
    }

    /// Decodes persisted engine values with fail-closed compatibility.
    ///
    /// - Parameter decoder: Decoder containing one engine string.
    /// - Throws: An error when the payload is not a string.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(persistedRawValue: try container.decode(String.self))
    }

    /// Encodes the canonical spelling used by settings and snapshots.
    ///
    /// - Parameter encoder: Encoder that receives the canonical raw value.
    /// - Throws: An error when the encoder cannot accept the string.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Parses a user-facing engine token without silently falling back.
    /// Settings decoding remains fail-closed through ``init(rawValue:)``;
    /// command-line and socket callers use this parser so a typo is reported.
    ///
    /// - Parameter rawValue: User-provided engine spelling.
    /// - Returns: A recognized engine, or `nil` for an invalid option.
    public static func parse(_ rawValue: String?) -> BrowserEngineKind? {
        guard let rawValue else { return nil }
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "webkit":
            return .webkit
        case "chromium", "chrome", "headless-shell":
            return .chromium
        default:
            return nil
        }
    }

    /// Whether a control/CLI `type` token resolves to a browser surface. The
    /// control-socket and command-line layers use the same normalization as
    /// the app's panel-type parser so an engine option can never be silently
    /// ignored for a terminal or simulator surface.
    ///
    /// - Parameter rawValue: User-provided panel type spelling.
    /// - Returns: `true` only when the spelling denotes a browser panel.
    public static func isBrowserPanelType(_ rawValue: String?) -> Bool {
        guard let rawValue else { return false }
        let normalized = rawValue
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
        return normalized == "browser"
    }

    /// Localized validation text for an unrecognized engine option.
    public static var invalidOptionMessage: String {
        String(
            localized: "browser.engine.error.invalid",
            defaultValue: "--engine requires webkit or chromium"
        )
    }

    /// Localized validation text for using an engine on a non-browser surface.
    public static var browserOnlyOptionMessage: String {
        String(
            localized: "browser.engine.error.browserOnly",
            defaultValue: "--engine is only supported when creating a browser pane or surface"
        )
    }

}
