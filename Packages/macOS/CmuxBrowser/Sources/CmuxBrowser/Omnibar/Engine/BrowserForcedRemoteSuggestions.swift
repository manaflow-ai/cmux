public import Foundation

/// Deterministic UI-test override for the omnibar's remote search suggestions.
///
/// Production builds never set the override, so `parse()` returns `nil` and the
/// omnibar falls back to its live network suggestion path. UI tests inject a
/// JSON array of strings through either the `CMUX_UI_TEST_REMOTE_SUGGESTIONS_JSON`
/// environment variable or a `UserDefaults` key of the same name, which lets a
/// test pin the exact suggestion list rendered without depending on external
/// network behavior.
///
/// The type is a `Sendable` value: it carries only the resolved raw JSON string
/// (or `nil`), captured at construction by probing the injected `ProcessInfo`
/// and `UserDefaults`. The probe reads the environment first and falls back to
/// the defaults string, matching the legacy inline behavior byte-for-byte.
public struct BrowserForcedRemoteSuggestions: Sendable, Equatable {
    /// The environment/defaults key carrying the JSON suggestion override.
    public static let environmentKey = "CMUX_UI_TEST_REMOTE_SUGGESTIONS_JSON"

    /// The raw JSON-array string captured from the environment or defaults, or
    /// `nil` when the override is not set in either source.
    public let raw: String?

    /// Creates an override holder from an already-resolved raw JSON string.
    ///
    /// - Parameter raw: The raw JSON-array string, or `nil` when no override is
    ///   set.
    public init(raw: String?) {
        self.raw = raw
    }

    /// Probes `processInfo` then `defaults` for the override raw string.
    ///
    /// Matches the legacy lookup order: the environment variable wins, and the
    /// `UserDefaults` string is the fallback.
    ///
    /// - Parameters:
    ///   - processInfo: The process whose environment is read first.
    ///   - defaults: The defaults store read when the environment is unset.
    public init(processInfo: ProcessInfo, defaults: UserDefaults) {
        self.raw = processInfo.environment[Self.environmentKey]
            ?? defaults.string(forKey: Self.environmentKey)
    }

    /// Whether a remote-suggestion override is present in either source.
    ///
    /// Mirrors the legacy `remoteSuggestionsEnabled` forced-on branch, which
    /// returned `true` whenever the env var or defaults string was non-`nil`,
    /// regardless of whether the JSON parsed to a usable list.
    public var isActive: Bool {
        raw != nil
    }

    /// Parses the captured raw JSON into a trimmed, non-empty suggestion list.
    ///
    /// Decodes the raw string as a JSON array, keeps only string elements,
    /// trims each on whitespace and newlines, drops the empties, and returns
    /// `nil` when the override is unset, unparseable, or yields no values. This
    /// is the exact transform the omnibar and `BrowserSearchSuggestionService`
    /// previously each open-coded.
    ///
    /// - Returns: The forced suggestion strings, or `nil` when none apply.
    public func parse() -> [String]? {
        guard let raw,
              let data = raw.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return nil
        }

        let values = parsed.compactMap { item -> String? in
            guard let s = item as? String else { return nil }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return values.isEmpty ? nil : values
    }
}
