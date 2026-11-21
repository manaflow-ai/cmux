import Foundation

/// A title as a tab shows it: its text and what a terminal's leading status glyphs said
/// (plans/cmux-next/osc-titles.md).
///
/// Agents animate their title: Claude Code writes `⠂ Fix the login bug`, `⠐ Fix the login bug`, … while it works and
/// `✳ Fix the login bug` when it waits. The daemon splits it (`TabTitle::terminal` in cmux-tui-core's
/// `terminal_title.rs`) and sends the text and the activity; it sends nothing for a spinner frame, so the app holds no
/// raw title and redraws nothing per frame (plans/cmux-next/main-thread-scheduling.md, D2).
public struct TerminalTitle: Equatable, Sendable {
    /// Shell names a terminal reports while idle; they carry no information
    /// about the work, so callers may use the terminal's working directory.
    public static func isBareShell(_ title: String) -> Bool {
        let title = title.hasPrefix("-") ? String(title.dropFirst()) : title
        return ["zsh", "bash", "fish", "sh", "nu", "dash", "ksh", "tcsh", "pwsh", "login", "~"].contains(title)
    }

    /// What a leading status glyph says about the program (wire `activity` / `title_activity`).
    public enum Activity: String, Equatable, Sendable {
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

    /// A title already split (by the daemon), or a page's.
    ///
    /// - Parameters:
    ///   - text: the text a tab shows.
    ///   - activity: what a stripped glyph said; nil for none.
    public init(text: String, activity: Activity? = nil) {
        self.text = text
        self.activity = activity
    }
}
