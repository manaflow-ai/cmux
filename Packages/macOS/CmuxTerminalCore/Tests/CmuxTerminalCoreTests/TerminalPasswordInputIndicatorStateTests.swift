import Foundation
import Testing
@testable import CmuxTerminalCore

@Suite("Terminal password input indicator state")
struct TerminalPasswordInputIndicatorStateTests {
    private typealias Keystroke = TerminalPasswordInputIndicatorState.Keystroke

    @Test("Keystrokes are ignored until echo goes off")
    func inactiveIgnoresKeystrokes() {
        var state = TerminalPasswordInputIndicatorState()
        let changed1 = state.record(.insert(count: 1))
        #expect(changed1 == false)
        #expect(state.isActive == false)
        #expect(state.typedCount == 0)
    }

    @Test("Echo off, typing, backspace, then Enter resets the count")
    func echoOffCountThenSubmit() {
        var state = TerminalPasswordInputIndicatorState()
        let changed2 = state.setEchoDisabled(true)
        #expect(changed2)
        #expect(state.isActive)

        for _ in 0..<5 { state.record(.insert(count: 1)) }
        #expect(state.typedCount == 5)

        let changed3 = state.record(.deleteBackward)
        #expect(changed3)
        #expect(state.typedCount == 4)

        let changed4 = state.record(.submit)
        #expect(changed4)
        #expect(state.typedCount == 0)
        // A wrong sudo password re-prompts without echo coming back on.
        #expect(state.isActive)
    }

    @Test("Backspace on an empty line stays at zero")
    func backspaceFloorsAtZero() {
        var state = TerminalPasswordInputIndicatorState()
        state.setEchoDisabled(true)
        let changed5 = state.record(.deleteBackward)
        #expect(changed5 == false)
        #expect(state.typedCount == 0)
    }

    @Test("Echo coming back on deactivates and clears the count")
    func echoOnResets() {
        var state = TerminalPasswordInputIndicatorState()
        state.setEchoDisabled(true)
        state.record(.insert(count: 3))
        let changed6 = state.setEchoDisabled(false)
        #expect(changed6)
        #expect(state.isActive == false)
        #expect(state.typedCount == 0)
        let changed7 = state.setEchoDisabled(false)
        #expect(changed7 == false)
    }

    @Test("A new prompt starts from zero")
    func newPromptStartsEmpty() {
        var state = TerminalPasswordInputIndicatorState()
        state.setEchoDisabled(true)
        state.record(.insert(count: 2))
        state.setEchoDisabled(true)
        #expect(state.typedCount == 0)
    }

    @Test("Line kill and ignored keys")
    func clearLineAndIgnored() {
        var state = TerminalPasswordInputIndicatorState()
        state.setEchoDisabled(true)
        state.record(.insert(count: 4))
        let changed8 = state.record(.ignored)
        #expect(changed8 == false)
        #expect(state.typedCount == 4)
        let changed9 = state.record(.clearLine)
        #expect(changed9)
        #expect(state.typedCount == 0)
    }

    @Test("Classifier maps keys without keeping text")
    func classifier() {
        func classify(
            _ keyCode: UInt16,
            _ characters: String?,
            ignoring: String? = nil,
            control: Bool = false,
            command: Bool = false
        ) -> Keystroke {
            Keystroke.classify(
                keyCode: keyCode,
                characters: characters,
                charactersIgnoringModifiers: ignoring ?? characters,
                control: control,
                command: command
            )
        }

        #expect(classify(0, "a") == .insert(count: 1))
        #expect(classify(36, "\r") == .submit)
        #expect(classify(76, "\u{3}") == .submit)
        #expect(classify(51, "\u{7F}") == .deleteBackward)
        #expect(classify(32, "\u{15}", ignoring: "u", control: true) == .clearLine)
        #expect(classify(8, "\u{3}", ignoring: "c", control: true) == .clearLine)
        #expect(classify(4, "\u{8}", ignoring: "h", control: true) == .deleteBackward)
        #expect(classify(0, "\u{1}", ignoring: "a", control: true) == .ignored)
        #expect(classify(9, "v", command: true) == .ignored)
        #expect(classify(123, "\u{F702}") == .ignored)
        #expect(classify(53, "\u{1B}") == .ignored)
        #expect(classify(48, "\t") == .insert(count: 1))
        #expect(classify(0, nil) == .ignored)
        #expect(Keystroke.insertion(of: "ab\u{e9}") == .insert(count: 3))
        #expect(Keystroke.insertion(of: "") == .ignored)
    }
}
