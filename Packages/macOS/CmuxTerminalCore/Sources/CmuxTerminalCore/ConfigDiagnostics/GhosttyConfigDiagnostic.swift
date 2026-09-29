import Foundation

/// One diagnostic Ghostty reported while loading its configuration.
///
/// Ghostty formats file diagnostics as `<path>:<line>:<key>: <message>`;
/// ``filePath`` and ``line`` are parsed from that prefix so the notice can
/// open the offending file.
public struct GhosttyConfigDiagnostic: Equatable, Hashable, Sendable {
    /// Synthetic path prefix cmux uses when it loads its own inline config
    /// fragments (see `loadInlineGhosttyConfig`). Diagnostics from those are
    /// cmux bugs, not user errors.
    public static let cmuxInlineConfigPathPrefix = "/__cmux_inline__/"

    /// The full message exactly as Ghostty formatted it.
    public let message: String
    /// The config file the diagnostic points at, when it has a file location.
    public let filePath: String?
    /// The 1-based line in ``filePath``, when present.
    public let line: Int?
    /// The config key the diagnostic is about, when Ghostty included one.
    public let key: String?

    /// Parses a Ghostty diagnostic message.
    ///
    /// - Parameter message: The text from `ghostty_config_get_diagnostic`.
    public init(message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        self.message = trimmed
        let location = Self.parseFileLocation(trimmed)
        self.filePath = location.path
        self.line = location.line
        self.key = location.key
    }

    /// Whether the diagnostic comes from a cmux-generated inline fragment
    /// rather than a file the user can edit.
    public var isFromCmuxInlineConfig: Bool {
        filePath?.hasPrefix(Self.cmuxInlineConfigPathPrefix) == true
            || message.hasPrefix(Self.cmuxInlineConfigPathPrefix)
    }

    /// Whether the diagnostic is about a key cmux reads itself
    /// (``GhosttyConfig/cmuxOwnedKeys``). Ghostty rejects those as unknown
    /// fields, which is expected.
    public var isForCmuxOwnedKey: Bool {
        key.map(GhosttyConfig.cmuxOwnedKeys.contains) ?? false
    }

    private static func parseFileLocation(_ message: String) -> (path: String?, line: Int?, key: String?) {
        guard message.hasPrefix("/") || message.hasPrefix("~") else {
            // The embedded Ghostty config API can omit the synthetic source
            // location for diagnostics emitted while loading inherited or
            // inline configuration. Keep cmux-owned keys filterable in that
            // form too (the notice would otherwise show the exact noise this
            // policy is meant to suppress).
            return (nil, nil, parseCmuxOwnedKey(message))
        }
        // Find the first ":<digits>:" after the path.
        var searchStart = message.startIndex
        while let colon = message[searchStart...].firstIndex(of: ":") {
            let digitsStart = message.index(after: colon)
            let digits = message[digitsStart...].prefix(while: \.isASCIIDigit)
            let afterDigits = message.index(digitsStart, offsetBy: digits.count)
            if !digits.isEmpty,
               afterDigits < message.endIndex,
               message[afterDigits] == ":",
               let line = Int(digits) {
                let rest = message[message.index(after: afterDigits)...]
                return (String(message[..<colon]), line, parseKey(rest))
            }
            searchStart = digitsStart
        }
        return (nil, nil, nil)
    }

    /// Ghostty writes `<key>: <message>` after the location, or
    /// ` <message>` when the diagnostic has no key.
    private static func parseKey(_ rest: Substring) -> String? {
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let key = rest[..<colon]
        guard !key.isEmpty, !key.contains(where: \.isWhitespace) else { return nil }
        return String(key)
    }

    private static func parseCmuxOwnedKey(_ message: String) -> String? {
        guard let colon = message.firstIndex(of: ":") else { return nil }
        let candidate = message[..<colon]
        guard !candidate.isEmpty,
              !candidate.contains(where: \.isWhitespace),
              GhosttyConfig.cmuxOwnedKeys.contains(String(candidate)) else {
            return nil
        }
        return String(candidate)
    }
}

private extension Character {
    var isASCIIDigit: Bool {
        isASCII && isNumber
    }
}
