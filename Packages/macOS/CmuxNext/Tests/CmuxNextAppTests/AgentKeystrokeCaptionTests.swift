import CmuxAgentCursor
import CmuxNextAgentCursor
import Testing

/// The keystroke caption beside an agent's cursor (user, 2026-10-18: "a
/// small keystroke overlay showing typed text/keys (mask password
/// fields)"): typing in a run reads as one line, a fill replaces it, a
/// shortcut shows alone, and masked text stays dots.
struct AgentKeystrokeCaptionTests {
    private func key(_ key: String, text: String? = nil, _ modifiers: [String] = []) -> AgentTyping {
        AgentTyping(text: text, key: key, modifiers: modifiers)
    }

    @Test func keysTypedInARunReadAsOneLine() {
        var caption = AgentKeystrokeCaption()
        var shown: [String?] = []
        for (i, letter) in "hello".enumerated() {
            shown.append(caption.apply(kind: .key, typing: key(String(letter), text: String(letter)), tMs: Double(i) * 50))
        }
        #expect(shown == ["h", "he", "hel", "hell", "hello"])
        #expect(caption.apply(kind: .key, typing: key("Backspace"), tMs: 300) == "hell", "Backspace takes the last character")
    }

    @Test func aPauseStartsANewLineAndAPointerInputEndsIt() {
        var caption = AgentKeystrokeCaption()
        _ = caption.apply(kind: .type, typing: AgentTyping(text: "cats"), tMs: 0)
        #expect(caption.apply(kind: .type, typing: AgentTyping(text: "dogs"), tMs: 5000) == "dogs")
        #expect(caption.apply(kind: .click, typing: nil, tMs: 5100) == nil)
        #expect(caption.apply(kind: .type, typing: AgentTyping(text: "x"), tMs: 5200) == "x")
    }

    @Test func aFillReplacesTheLine() {
        var caption = AgentKeystrokeCaption()
        _ = caption.apply(kind: .type, typing: AgentTyping(text: "old"), tMs: 0)
        #expect(caption.apply(kind: .type, typing: AgentTyping(text: "new value", replace: true), tMs: 10) == "new value")
    }

    @Test func shortcutsAndSpecialKeysShowAsSymbolsAlone() {
        var caption = AgentKeystrokeCaption()
        _ = caption.apply(kind: .type, typing: AgentTyping(text: "query"), tMs: 0)
        #expect(caption.apply(kind: .key, typing: key("a", text: "a", ["Meta"]), tMs: 10) == "⌘A")
        #expect(caption.apply(kind: .key, typing: key("Enter"), tMs: 20) == "⏎")
        #expect(AgentKeystrokeCaption.label(key: "Tab", modifiers: ["Shift"]) == "⇧⇥")
        #expect(AgentKeystrokeCaption.label(key: "ArrowDown", modifiers: ["Control", "Alt", "Meta"]) == "⌃⌥⌘↓")
        #expect(AgentKeystrokeCaption.label(key: "F5", modifiers: []) == "F5")
    }

    @Test func maskedTextStaysDotsAndALongLineKeepsItsEnd() {
        var caption = AgentKeystrokeCaption()
        #expect(caption.apply(kind: .type, typing: AgentTyping(text: "••••", masked: true), tMs: 0) == "••••")
        #expect(caption.apply(kind: .key, typing: AgentTyping(text: "•", masked: true), tMs: 10) == "•••••",
                "a masked key arrives without its name")
        var long = AgentKeystrokeCaption()
        let shown = long.apply(kind: .type, typing: AgentTyping(text: String(repeating: "a", count: 40) + "END"), tMs: 0)
        #expect(shown?.hasPrefix("…") == true)
        #expect(shown?.hasSuffix("END") == true)
        #expect(shown?.count == AgentKeystrokeCaption.maxShownCharacters)
    }

    @Test func anInputWithoutTypingChangesNothing() {
        var caption = AgentKeystrokeCaption()
        #expect(caption.apply(kind: .type, typing: nil, tMs: 0) == nil)
        #expect(caption.apply(kind: .key, typing: AgentTyping(), tMs: 0) == nil)
    }
}
