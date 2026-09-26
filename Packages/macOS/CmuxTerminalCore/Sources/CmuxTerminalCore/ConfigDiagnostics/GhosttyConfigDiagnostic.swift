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

    /// Parses a Ghostty diagnostic message.
    ///
    /// - Parameter message: The text from `ghostty_config_get_diagnostic`.
    public init(message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        self.message = trimmed
        let location = Self.parseFileLocation(trimmed)
        self.filePath = location.path
        self.line = location.line
    }

    /// Whether the diagnostic comes from a cmux-generated inline fragment
    /// rather than a file the user can edit.
    public var isFromCmuxInlineConfig: Bool {
        filePath?.hasPrefix(Self.cmuxInlineConfigPathPrefix) == true
            || message.hasPrefix(Self.cmuxInlineConfigPathPrefix)
    }

    private static func parseFileLocation(_ message: String) -> (path: String?, line: Int?) {
        guard message.hasPrefix("/") || message.hasPrefix("~") else { return (nil, nil) }
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
                return (String(message[..<colon]), line)
            }
            searchStart = digitsStart
        }
        return (nil, nil)
    }
}

private extension Character {
    var isASCIIDigit: Bool {
        isASCII && isNumber
    }
}
