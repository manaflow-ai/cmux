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
}
