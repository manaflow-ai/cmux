import Foundation

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

    /// Creates a parser for Claude Code's resume prompt.
    public init() {}

    /// True when the resume menu is currently on screen. Requires all three
    /// numbered option rows in one contiguous block — a deliberately strict
    /// signal so the responder never synthesizes keys just because matching
    /// phrases appear in ordinary terminal output.
    public func isVisible(in screen: String) -> Bool {
        menuOptionBlock(in: screen) != nil
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

        guard let optionLines = menuOptionBlock(in: screen) else { return nil }

        // Single pass over the option block: find the target row and the row
        // currently carrying the selection pointer.
        var targetPosition: Int?
        var pointerPosition: Int?
        for (index, line) in optionLines.enumerated() {
            if line.contains(targetLabel) {
                targetPosition = index
            }
            if line.contains(where: { Self.pointerGlyphs.contains($0) }) {
                pointerPosition = index
            }
        }

        guard let targetPosition else {
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

    private func menuOptionBlock(in screen: String) -> [String]? {
        var window: [String] = []
        var labels: [Int] = []
        var latestCompleteBlock: [String]?

        for rawLine in screen.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            guard let label = optionLabelIndex(in: line) else {
                window.removeAll(keepingCapacity: true)
                labels.removeAll(keepingCapacity: true)
                if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    latestCompleteBlock = nil
                }
                continue
            }

            window.append(line)
            labels.append(label)
            if window.count > 3 {
                window.removeFirst()
                labels.removeFirst()
            }

            if window.count == 3 && Set(labels).count == 3 {
                latestCompleteBlock = window
            }
        }

        return latestCompleteBlock
    }

    private func optionLabelIndex(in line: String) -> Int? {
        var row = line.trimmingCharacters(in: .whitespaces)
        if let first = row.first, Self.pointerGlyphs.contains(first) {
            row.removeFirst()
            row = row.trimmingCharacters(in: .whitespaces)
        }
        guard let numberSeparator = row.firstIndex(of: ".") else { return nil }
        let number = row[..<numberSeparator]
        guard !number.isEmpty, number.allSatisfy(\.isNumber) else { return nil }

        let labelStart = row.index(after: numberSeparator)
        let labelText = row[labelStart...]
        if labelText.contains(Self.summaryLabel) { return 0 }
        if labelText.contains(Self.fullLabel) { return 1 }
        if labelText.contains(Self.dontAskLabel) { return 2 }
        return nil
    }
}
