public import CmuxAgentCursor

/// The keystroke caption of one agent session: what it is typing, shown
/// next to its cursor (user, 2026-10-18: "a small keystroke overlay
/// showing typed text/keys (mask password fields)"). Pure: the overlay
/// model feeds it each input and draws what it returns.
///
/// Typing in a run (inputs less than ``joinWindowMs`` apart) adds to one
/// line, so `keyboard.type("hello")` reads "hello", not five captions; a
/// fill replaces the line; a shortcut or a special key (`⌘A`, `⏎`) shows
/// alone; a pointer input ends the run. Masked text arrives as dots from
/// the host and stays dots.
public struct AgentKeystrokeCaption: Sendable, Equatable {
    /// Inputs this close (ms) continue one line of typing.
    public static let joinWindowMs: Double = 1500
    /// The most characters the caption shows; a longer line keeps its end.
    public static let maxShownCharacters = 32

    /// The current line of typing.
    public private(set) var line = ""
    private var lastMs: Double?

    /// An empty caption.
    public init() {}

    /// Applies one input of the session.
    ///
    /// - Parameters:
    ///   - kind: The input's kind.
    ///   - typing: What it types (type and key events), when the host sent it.
    ///   - tMs: The input's host time in ms.
    /// - Returns: The caption to show now, or nil to leave the caption as it is.
    public mutating func apply(kind: AutomationInputEvent.Kind, typing: AgentTyping?, tMs: Double) -> String? {
        switch kind {
        case .move, .click, .doubleClick, .rightClick, .drag, .scroll:
            end()
            return nil
        case .type:
            guard let typing, let text = typing.text else { return nil }
            if typing.replace {
                line = text
                lastMs = tMs
                return shown
            }
            return add(text, at: tMs)
        case .key:
            guard let typing else { return nil }
            let command = typing.modifiers.contains { $0 != "Shift" }
            if !command, let text = typing.text, text.count == 1 {
                return add(text, at: tMs)
            }
            if !command, typing.key == "Backspace", continues(at: tMs), !line.isEmpty {
                line.removeLast()
                lastMs = tMs
                return line.isEmpty ? Self.label(key: "Backspace", modifiers: []) : shown
            }
            guard let key = typing.key else { return nil }
            end()
            return Self.label(key: key, modifiers: typing.modifiers)
        }
    }

    /// The line as shown: its last ``maxShownCharacters`` characters.
    var shown: String {
        guard line.count > Self.maxShownCharacters else { return line }
        return "…" + line.suffix(Self.maxShownCharacters - 1)
    }

    private func continues(at tMs: Double) -> Bool {
        guard let lastMs else { return false }
        return tMs - lastMs <= Self.joinWindowMs
    }

    private mutating func add(_ text: String, at tMs: Double) -> String {
        if !continues(at: tMs) { line = "" }
        line += text
        lastMs = tMs
        return shown
    }

    private mutating func end() {
        line = ""
        lastMs = nil
    }

    /// A key as macOS menus write it: modifiers `⌃⌥⇧⌘` in that order, then
    /// the key's symbol (`⏎`, `⇥`, `⌫`, arrows) or its value, letters
    /// upper-cased. Symbols, not words, so the caption needs no translation.
    ///
    /// - Parameters:
    ///   - key: The DOM key value.
    ///   - modifiers: The held modifiers.
    /// - Returns: The label, for example `⌘A` or `⇧⏎`.
    public static func label(key: String, modifiers: [String]) -> String {
        let order: [(String, String)] = [("Control", "⌃"), ("Alt", "⌥"), ("Shift", "⇧"), ("Meta", "⌘")]
        let held = order.filter { modifiers.contains($0.0) && $0.0 != key }.map(\.1).joined()
        let symbols: [String: String] = [
            "Enter": "⏎", "Tab": "⇥", "Backspace": "⌫", "Delete": "⌦", "Escape": "⎋", " ": "␣",
            "ArrowUp": "↑", "ArrowDown": "↓", "ArrowLeft": "←", "ArrowRight": "→",
            "PageUp": "⇞", "PageDown": "⇟", "Home": "↖", "End": "↘",
            "Control": "⌃", "Alt": "⌥", "Shift": "⇧", "Meta": "⌘",
        ]
        let name = symbols[key] ?? (key.count == 1 ? key.uppercased() : key)
        return held + name
    }
}
