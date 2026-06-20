import Foundation

/// A single key cmux synthesizes into a Claude agent pane to drive its
/// compacted-session resume menu. Maps to cmux's named-key sender so libghostty
/// encodes the correct escape sequence for the pane's cursor mode.
public enum ClaudeResumeKey: String, Sendable {
    case up
    case down
    case enter

    /// Name understood by `TerminalSurface.sendNamedKey` / `TerminalPanel.sendNamedKeyResult`.
    public var namedKey: String { rawValue }
}

/// Pure, UI-free detection and keystroke planning for Claude Code's
/// compacted-session resume menu. Kept free of AppKit/ghostty so it is fully
/// unit-testable; the app-side controller supplies the rendered screen text and
/// performs the side effects (reading the pane, sending keys).
public enum ClaudeResumePrompt {
    /// Distinctive option labels Claude Code prints for the resume menu. Matching
    /// the two "Resume …" labels together is specific enough not to fire on
    /// ordinary conversation. The apostrophe in "Don't ask me again" is avoided
    /// on purpose (straight-vs-curly quote ambiguity across renderers).
    public static let summaryLabel = "Resume from summary"
    public static let fullLabel = "Resume full session as-is"
    public static let dontAskLabel = "ask me again"

    /// Selection-pointer glyphs Ink-style menus render next to the active row.
    private static let pointerGlyphs: Set<Character> = ["❯", "›", "▶", "▸", "➤"]

    /// True when the resume menu is currently on screen.
    public static func isVisible(in screen: String) -> Bool {
        screen.contains(summaryLabel) && screen.contains(fullLabel)
    }

    /// The keys needed to land on `mode`'s option and confirm it, given the
    /// rendered screen. Returns nil when the menu isn't present, the mode is
    /// `.ask` (no automation), or the target option can't be located.
    ///
    /// Selection model: the menu's option rows are detected by their labels, in
    /// display order. The currently highlighted row is found by its pointer
    /// glyph; if no glyph is rendered we assume the first (recommended) row is
    /// highlighted, which matches Claude's default. We then move up/down to the
    /// target row and press Enter. Detecting the row order (rather than
    /// hard-coding "press Down once") keeps this working if Claude reorders the
    /// options.
    public static func keystrokes(for mode: ClaudeResumeMode, in screen: String) -> [ClaudeResumeKey]? {
        guard mode != .ask, isVisible(in: screen) else { return nil }

        let targetLabel: String
        switch mode {
        case .full: targetLabel = fullLabel
        case .summary: targetLabel = summaryLabel
        case .ask: return nil
        }

        let optionLines: [String] = screen
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { line in
                line.contains(summaryLabel) || line.contains(fullLabel) || line.contains(dontAskLabel)
            }

        guard let targetPosition = optionLines.firstIndex(where: { $0.contains(targetLabel) }) else {
            return nil
        }
        let currentPosition = optionLines.firstIndex { line in
            line.contains { pointerGlyphs.contains($0) }
        } ?? 0

        var keys: [ClaudeResumeKey] = []
        let delta = targetPosition - currentPosition
        if delta > 0 {
            keys.append(contentsOf: Array(repeating: .down, count: delta))
        } else if delta < 0 {
            keys.append(contentsOf: Array(repeating: .up, count: -delta))
        }
        keys.append(.enter)
        return keys
    }
}

/// One-shot responder armed for a single resumed Claude pane. The controller
/// feeds it the pane's rendered screen on each poll; it returns the keys to send
/// exactly once — when the menu first appears — then reports having responded so
/// the controller can disarm it.
public final class ClaudeResumeAutoResponder {
    public let mode: ClaudeResumeMode
    public private(set) var hasResponded = false

    public init(mode: ClaudeResumeMode) {
        self.mode = mode
    }

    /// Returns the keys to send if the menu is now visible and we haven't already
    /// responded; nil otherwise. Marks itself responded when it returns keys so a
    /// later call never double-fires.
    public func evaluate(screen: String) -> [ClaudeResumeKey]? {
        guard !hasResponded, mode != .ask else { return nil }
        guard let keys = ClaudeResumePrompt.keystrokes(for: mode, in: screen) else { return nil }
        hasResponded = true
        return keys
    }
}
