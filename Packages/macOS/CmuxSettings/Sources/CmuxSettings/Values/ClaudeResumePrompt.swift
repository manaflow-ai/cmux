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
public struct ClaudeResumePrompt: Sendable {
    /// Distinctive option labels Claude Code prints for the resume menu. Matching
    /// the two "Resume …" labels together is specific enough not to fire on
    /// ordinary conversation. The apostrophe in "Don't ask me again" is avoided
    /// on purpose (straight-vs-curly quote ambiguity across renderers).
    private static let summaryLabel = "Resume from summary"
    private static let fullLabel = "Resume full session as-is"
    private static let dontAskLabel = "ask me again"

    /// Selection-pointer glyphs Ink-style menus render next to the active row.
    private static let pointerGlyphs: Set<Character> = ["❯", "›", "▶", "▸", "➤"]

    public init() {}

    /// True when the resume menu is currently on screen. Requires all three
    /// option labels together — a deliberately strict signal so the responder
    /// never synthesizes keys just because one phrase appears in ordinary
    /// terminal output.
    public func isVisible(in screen: String) -> Bool {
        screen.contains(Self.summaryLabel) && screen.contains(Self.fullLabel) && screen.contains(Self.dontAskLabel)
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
    public func keystrokes(for mode: ClaudeResumeMode, in screen: String) -> [ClaudeResumeKey]? {
        guard mode != .ask, isVisible(in: screen) else { return nil }

        let targetLabel: String
        switch mode {
        case .full: targetLabel = Self.fullLabel
        case .summary: targetLabel = Self.summaryLabel
        case .ask: return nil
        }

        // Single pass over the screen: collect the menu's option rows (in display
        // order) and note which row currently carries the selection pointer.
        var optionLines: [String] = []
        var pointerPosition: Int?
        for rawLine in screen.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            guard line.contains(Self.summaryLabel) || line.contains(Self.fullLabel) || line.contains(Self.dontAskLabel) else {
                continue
            }
            if line.contains(where: { Self.pointerGlyphs.contains($0) }) {
                pointerPosition = optionLines.count
            }
            optionLines.append(line)
        }

        guard let targetPosition = optionLines.firstIndex(where: { $0.contains(targetLabel) }) else {
            return nil
        }
        // Claude highlights the recommended (first) row by default; if no pointer
        // glyph rendered, assume the first option is selected.
        let currentPosition = pointerPosition ?? 0

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
/// when the menu appears, then the controller confirms delivery so a failed
/// synthetic-key send can be retried on the next screen sample.
public final class ClaudeResumeAutoResponder {
    public let mode: ClaudeResumeMode
    public private(set) var hasResponded = false
    private let prompt: ClaudeResumePrompt

    public init(mode: ClaudeResumeMode, prompt: ClaudeResumePrompt = ClaudeResumePrompt()) {
        self.mode = mode
        self.prompt = prompt
    }

    /// Returns the keys to send if the menu is now visible and we haven't already
    /// responded; nil otherwise. The controller calls ``confirmDelivered()`` only
    /// after every planned key reaches, or is queued for, the terminal surface.
    public func evaluate(screen: String) -> [ClaudeResumeKey]? {
        guard !hasResponded, mode != .ask else { return nil }
        return prompt.keystrokes(for: mode, in: screen)
    }

    public func confirmDelivered() {
        hasResponded = true
    }
}
