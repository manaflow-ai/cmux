import Testing
@testable import CmuxTerminal

@Suite struct TerminalKeyInputPlannerTests {
    private let planner = TerminalKeyInputPlanner()

    @Test func translatedOptionInputUsesTranslatedText() {
        let actions = planner.actions(for: snapshot(translatedText: "n"))

        #expect(actions == [.sendKey(text: "n", composing: false)])
    }

    @Test func inputSourceChangeConsumesPhysicalKey() {
        let actions = planner.actions(for: snapshot(
            inputSourceChanged: true,
            translatedText: " "
        ))

        #expect(actions.isEmpty)
    }

    @Test func activeCompositionKeepsTranslatedKeyComposing() {
        let actions = planner.actions(for: snapshot(
            hasMarkedText: true,
            translatedText: "ᄒ"
        ))

        #expect(actions == [.sendKey(text: "ᄒ", composing: true)])
    }

    @Test func committedPreeditTextAndNavigationRemainOrdered() {
        let actions = planner.actions(for: snapshot(
            hadMarkedText: true,
            committedText: ["한"],
            key: .arrowRight,
            translatedText: nil
        ))

        #expect(actions == [
            .sendCommittedText("한"),
            .sendKey(text: nil, composing: false),
        ])
    }

    @Test func plainLeftArrowDoesNotReplayAfterPreeditCommit() {
        let actions = planner.actions(for: snapshot(
            hadMarkedText: true,
            committedText: ["한"],
            key: .arrowLeft,
            translatedText: nil
        ))

        #expect(actions == [.sendCommittedText("한")])
    }

    @Test func modifiedLeftArrowReplaysAfterPreeditCommit() {
        let actions = planner.actions(for: snapshot(
            hadMarkedText: true,
            committedText: ["한"],
            key: .arrowLeft,
            hasModifier: true,
            translatedText: nil
        ))

        #expect(actions == [
            .sendCommittedText("한"),
            .sendKey(text: nil, composing: false),
        ])
    }

    @Test func committedTextWithoutPriorPreeditUsesPhysicalKey() {
        let actions = planner.actions(for: snapshot(
            committedText: ["你"],
            translatedText: nil
        ))

        #expect(actions == [.sendKey(text: "你", composing: false)])
    }

    @Test func composingControlTextStaysInsideAppKit() {
        let actions = planner.actions(for: snapshot(
            hadMarkedText: true,
            translatedText: "h",
            rawText: "\u{8}"
        ))

        #expect(actions.isEmpty)
    }

    private func snapshot(
        hadMarkedText: Bool = false,
        hasMarkedText: Bool = false,
        inputSourceChanged: Bool = false,
        committedText: [String] = [],
        key: TerminalKeyInputKey = .other,
        hasModifier: Bool = false,
        translatedText: String?,
        rawText: String? = nil
    ) -> TerminalKeyInputSnapshot {
        TerminalKeyInputSnapshot(
            hadMarkedText: hadMarkedText,
            hasMarkedText: hasMarkedText,
            inputSourceChanged: inputSourceChanged,
            committedText: committedText,
            event: TerminalKeyInputEvent(
                key: key,
                hasModifier: hasModifier,
                translatedText: translatedText,
                rawText: rawText ?? translatedText
            )
        )
    }
}
