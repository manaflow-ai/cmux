public import Foundation

/// Builds the startup environment that hands captured terminal scrollback to a
/// freshly launched terminal for replay. It normalizes the captured text
/// (strips theme-baked terminal-color OSC sequences, truncates to the persisted
/// limit, and brackets the result with ANSI resets), writes it to a temp replay
/// file, and returns the environment variable pointing at that file.
///
/// An instance carries the `ScrollbackTruncation` it applies, so callers can
/// configure the limit while the default instance reproduces the legacy
/// behavior. The pure text transforms are file-private statics; only the
/// truncation depends on instance state.
public struct SessionScrollbackReplay: Sendable {
    /// Environment variable a restored terminal reads to locate its replay file.
    public static let environmentKey = "CMUX_RESTORE_SCROLLBACK_FILE"

    private static let directoryName = "cmux-session-scrollback"
    private static let ansiEscape = "\u{001B}"
    private static let ansiReset = "\u{001B}[0m"

    private let truncation: ScrollbackTruncation

    /// Creates a replay builder. The default truncation reproduces the legacy
    /// persistence limit.
    public init(truncation: ScrollbackTruncation = ScrollbackTruncation()) {
        self.truncation = truncation
    }

    /// Returns the startup environment carrying a replay-file path for the given
    /// scrollback, or an empty dictionary when the scrollback is empty,
    /// whitespace-only, or cannot be written.
    public func replayEnvironment(
        for scrollback: String?,
        tempDirectory: URL = FileManager.default.temporaryDirectory
    ) -> [String: String] {
        guard let replayText = normalizedScrollback(scrollback) else { return [:] }
        guard let replayFileURL = Self.writeReplayFile(
            contents: replayText,
            tempDirectory: tempDirectory
        ) else {
            return [:]
        }
        return [Self.environmentKey: replayFileURL.path]
    }

    private func normalizedScrollback(_ scrollback: String?) -> String? {
        guard let scrollback else { return nil }
        guard scrollback.contains(where: { !$0.isWhitespace }) else { return nil }
        // Restored history must not reconfigure the live terminal's colors: the
        // active theme owns the default foreground/background (and palette), so
        // default-colored cells track it. The captured scrollback bakes the
        // capture-time theme via terminal-color OSC sequences (e.g. OSC 10/11),
        // which would otherwise survive a theme change as white-on-white output
        // (issue #5165). Strip them before replay.
        let themePortable = Self.strippingTerminalColorOSCSequences(scrollback)
        guard let truncated = truncation.truncated(themePortable) else { return nil }
        return Self.ansiSafeReplayText(truncated)
    }

    /// Preserve ANSI color state safely across replay boundaries.
    private static func ansiSafeReplayText(_ text: String) -> String {
        guard text.contains(ansiEscape) else { return text }
        var output = text
        if !output.hasPrefix(ansiReset) {
            output = ansiReset + output
        }
        if !output.hasSuffix(ansiReset) {
            output += ansiReset
        }
        return output
    }

    /// Removes terminal-color OSC sequences (palette entries and the dynamic
    /// foreground/background/cursor/highlight colors plus their resets) from
    /// captured scrollback so the restored history does not reconfigure the live
    /// terminal's colors.
    ///
    /// Ghostty's `write_screen_file:copy,vt` export bakes the capture-time theme
    /// by prepending `OSC 10` / `OSC 11` (and resolving palette entries). Replaying
    /// those into a freshly launched terminal would override the active theme's
    /// default colors, so restored default-colored cells would keep the old theme
    /// (white-on-white after a theme change — issue #5165). Explicit per-cell SGR
    /// colors and every non-color escape sequence (titles, hyperlinks, prompt
    /// marks, …) are preserved verbatim.
    private static func strippingTerminalColorOSCSequences(_ text: String) -> String {
        let escByte: UInt8 = 0x1B
        let oscIntroducer: UInt8 = 0x5D // ]
        let bel: UInt8 = 0x07
        let backslash: UInt8 = 0x5C
        let zero: UInt8 = 0x30
        let nine: UInt8 = 0x39

        let bytes = Array(text.utf8)
        guard bytes.contains(escByte) else { return text }

        var output = [UInt8]()
        output.reserveCapacity(bytes.count)
        let count = bytes.count
        var index = 0
        while index < count {
            let byte = bytes[index]
            guard byte == escByte,
                  index + 1 < count,
                  bytes[index + 1] == oscIntroducer else {
                output.append(byte)
                index += 1
                continue
            }

            // Parse the OSC numeric command (Ps) following `ESC ]`.
            var cursor = index + 2
            var code = 0
            var sawDigit = false
            while cursor < count, bytes[cursor] >= zero, bytes[cursor] <= nine {
                code = (code * 10) + Int(bytes[cursor] - zero)
                sawDigit = true
                cursor += 1
                if code > 100_000 { break } // overflow guard for malformed input
            }

            guard sawDigit, isTerminalColorOSCCode(code) else {
                // Not a terminal-color OSC; emit `ESC` and resume scanning so the
                // rest of the preserved sequence is copied verbatim.
                output.append(byte)
                index += 1
                continue
            }

            // Consume through the OSC terminator (BEL or `ESC \` / ST). A truncated
            // (unterminated) color OSC at the end of the buffer is dropped as well.
            var end = cursor
            var terminated = false
            while end < count {
                if bytes[end] == bel {
                    end += 1
                    terminated = true
                    break
                }
                if bytes[end] == escByte, end + 1 < count, bytes[end + 1] == backslash {
                    end += 2
                    terminated = true
                    break
                }
                end += 1
            }
            index = terminated ? end : count
        }

        return String(decoding: output, as: UTF8.self)
    }

    /// Returns `true` for OSC command numbers that configure terminal colors
    /// (palette entries and the dynamic foreground/background/cursor/highlight
    /// colors plus their resets), which restored scrollback must not carry.
    private static func isTerminalColorOSCCode(_ code: Int) -> Bool {
        switch code {
        case 4, 5, 104, 105: return true // palette / special color set + reset
        case 10...19: return true        // dynamic colors (fg, bg, cursor, …)
        case 110...119: return true      // dynamic color resets
        default: return false
        }
    }

    private static func writeReplayFile(contents: String, tempDirectory: URL) -> URL? {
        guard let data = contents.data(using: .utf8) else { return nil }
        let directory = tempDirectory.appendingPathComponent(directoryName, isDirectory: true)

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            let fileURL = directory
                .appendingPathComponent(UUID().uuidString, isDirectory: false)
                .appendingPathExtension("txt")
            try data.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            return nil
        }
    }
}
