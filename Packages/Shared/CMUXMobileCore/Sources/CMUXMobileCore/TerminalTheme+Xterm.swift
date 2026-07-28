import Foundation

/// Errors emitted while constructing xterm's private host-configuration
/// preamble. The preamble is parsed by cmux's pinned xterm integration before
/// the baseline's standard OSC reset sequences are applied.
public enum TerminalThemeXtermPreambleError: Error, Equatable, Sendable {
    case invalidTheme
    case payloadTooLarge
}

public extension TerminalTheme {
    /// Private OSC identifier used only to install the host's configuration
    /// theme as xterm's reset base before replaying a terminal baseline.
    static let xtermConfigurationOSC = 777

    /// Encodes this complete validated theme as bounded base64url JSON in an
    /// OSC preamble. Keeping the metadata inside the VT payload preserves the
    /// transport's directly-consumable xterm byte stream.
    func xtermConfigurationPreambleBytes() throws -> Data {
        guard isValid else {
            throw TerminalThemeXtermPreambleError.invalidTheme
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = try encoder.encode(self)
        guard json.count < 12 * 1_024 else {
            throw TerminalThemeXtermPreambleError.payloadTooLarge
        }
        let encoded = json.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let preamble =
            "\u{1B}]\(Self.xtermConfigurationOSC);cmux-theme-v1;" +
            encoded +
            "\u{1B}\\"
        let bytes = Data(preamble.utf8)
        guard bytes.count < 16 * 1_024 else {
            throw TerminalThemeXtermPreambleError.payloadTooLarge
        }
        return bytes
    }
}
