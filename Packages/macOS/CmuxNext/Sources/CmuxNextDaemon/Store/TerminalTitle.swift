import Foundation

/// A terminal's title as a tab shows it: the text a program set with OSC 0/2,
/// without the status glyphs it puts in front (plans/cmux-next/osc-titles.md).
///
/// Agents animate their title: Claude Code writes `⠂ Fix the login bug`,
/// `⠐ Fix the login bug`, … while it works and `✳ Fix the login bug` when it
/// waits. Showing that raw would change the tab's text several times a
/// second. ``init(raw:)`` moves the leading glyphs into ``activity`` and
/// keeps ``text`` stable, so the strip lays out again only when the words change.
///
/// ```swift
/// let title = TerminalTitle(raw: "⠐ Fix the login bug")
/// title.text      // "Fix the login bug"
/// title.activity  // .working
/// ```
public struct TerminalTitle: Equatable, Sendable {
    /// Shell names a terminal reports while idle; they carry no information
    /// about the work, so callers may use the terminal's working directory.
    public static func isBareShell(_ title: String) -> Bool {
        let title = title.hasPrefix("-") ? String(title.dropFirst()) : title
        return ["zsh", "bash", "fish", "sh", "nu", "dash", "ksh", "tcsh", "pwsh", "login", "~"].contains(title)
    }

    /// What a leading status glyph says about the program.
    public enum Activity: Equatable, Sendable {
        /// A spinner frame (Braille dots, a turning circle): the program works.
        case working
        /// A resting marker (`✳`, `●`, `⏺`): the program waits.
        case idle
        /// A check mark: the program finished.
        case done
        /// A cross: the program failed.
        case failed
    }

    /// The title without its leading status glyphs; empty for none.
    public var text: String
    /// What the stripped glyphs said; nil when the title had none.
    public var activity: Activity?

    /// A title taken as is: a page's, or one already split.
    ///
    /// - Parameters:
    ///   - text: the text a tab shows.
    ///   - activity: what a stripped glyph said; nil for none.
    public init(text: String, activity: Activity? = nil) {
        self.text = text
        self.activity = activity
    }

    /// Splits `raw` into its text and the activity its leading glyphs name.
    ///
    /// - Parameter raw: the terminal's title as the daemon sent it (already
    ///   sanitized there: no control characters, at most 256 characters).
    public init(raw: String) {
        var rest = Substring(raw)
        var activity: Activity?
        while let first = rest.unicodeScalars.first, let found = Self.activity(of: first) {
            // The last glyph wins: `✳ ⠂ Task` reads as working.
            activity = found
            rest = Substring(rest.unicodeScalars.dropFirst())
            // A variation selector (`✔︎`) belongs to the glyph before it.
            while let next = rest.unicodeScalars.first, next.properties.isVariationSelector {
                rest = Substring(rest.unicodeScalars.dropFirst())
            }
            rest = rest.drop { $0.isWhitespace }
        }
        // Only glyphs, no words: keep them as the text so the tab is not blank.
        let words = rest.trimmingCharacters(in: .whitespaces)
        self.text = words.isEmpty ? raw.trimmingCharacters(in: .whitespaces) : words
        self.activity = activity
    }

    private static func activity(of scalar: Unicode.Scalar) -> Activity? {
        switch scalar.value {
        // Braille patterns: every terminal spinner frame (`⠋⠙⠹`, Claude's `⠂⠐`).
        case 0x2801...0x28FF: .working
        // Turning circles and half blocks used as spinners.
        case 0x25D0...0x25D3, 0x25F4...0x25F7, 0x2596...0x259F: .working
        // Claude Code's resting asterisks, a filled or empty dot, a record mark.
        case 0x2733, 0x2736, 0x273B, 0x273D, 0x2722, 0x00B7, 0x25CF, 0x25CB, 0x25C9, 0x23FA: .idle
        case 0x2713, 0x2714, 0x2705: .done
        case 0x2717, 0x2718, 0x274C: .failed
        default: nil
        }
    }
}
