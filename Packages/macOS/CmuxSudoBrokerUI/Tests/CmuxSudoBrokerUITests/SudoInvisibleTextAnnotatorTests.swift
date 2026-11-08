@testable import CmuxSudoBrokerUI
import CmuxSudoBroker
import Foundation
import Testing

@Suite("Sudo approval invisible-character annotation")
struct SudoInvisibleTextAnnotatorTests {
    @Test("Bidi overrides, isolates, zero-width and format controls become visible markers")
    func hiddenScalarsAreAnnotated() {
        let annotator = SudoInvisibleTextAnnotator()
        // An RLO override and PDF, an LRI/PDI isolate pair, a zero-width
        // space, a zero-width joiner, a BOM, a tag character and a carriage return.
        let text = "echo ok\u{202E}gnp.x\u{202C} \u{2066}a\u{2069}\u{200B}\u{200D}\u{FEFF}\u{E0041}\r\n\tdone"

        let annotation = annotator.annotate(text)

        #expect(annotation.display == "echo ok⟨U+202E⟩gnp.x⟨U+202C⟩ ⟨U+2066⟩a⟨U+2069⟩⟨U+200B⟩⟨U+200D⟩⟨U+FEFF⟩⟨U+E0041⟩⟨U+000D⟩\n\tdone")
        #expect(annotation.hiddenCharacterCount == 9)
        #expect(annotation.containsHiddenCharacters)
    }

    @Test("Ordinary scripts, including non-Latin text, are shown unchanged")
    func visibleTextIsUnchanged() {
        let text = "#!/bin/sh\n\techo 'こんにちは' café 👋🏽\n"

        let annotation = SudoInvisibleTextAnnotator().annotate(text)

        #expect(annotation.display == text)
        #expect(!annotation.containsHiddenCharacters)
    }

    @Test("Line separators and Hangul fillers are annotated")
    func deceptiveSeparatorsAreAnnotated() {
        let annotation = SudoInvisibleTextAnnotator().annotate("a\u{2028}b\u{3164}c\u{061C}")

        #expect(annotation.display == "a⟨U+2028⟩b⟨U+3164⟩c⟨U+061C⟩")
        #expect(annotation.hiddenCharacterCount == 3)
    }

    @Test("Presentation annotates display text without altering the reviewed script bytes")
    @MainActor
    func presentationKeepsExecutionBytes() {
        let script = "echo \u{202E}evil\n"
        let snapshot = SudoPendingRequest(
            request: SudoRequest(
                id: "hidden-1",
                reason: "update\u{200B}",
                requesterIdentity: SudoProcessIdentity(
                    processIdentifier: 42,
                    startSeconds: 1,
                    startMicroseconds: 2
                ),
                requesterCommand: "agent\u{2067}",
                currentDirectory: "/tmp",
                createdAt: Date(timeIntervalSince1970: 1)
            ),
            script: script
        )

        let presentation = SudoApprovalPresentation(snapshot: snapshot)

        #expect(presentation.script == script)
        #expect(Data(presentation.script.utf8) == Data(script.utf8))
        #expect(presentation.displayScript == "echo ⟨U+202E⟩evil\n")
        #expect(presentation.displayReason == "update⟨U+200B⟩")
        #expect(presentation.requesterSummary.contains("agent⟨U+2067⟩"))
        #expect(presentation.hiddenCharacterCount == 3)
        #expect(presentation.containsHiddenCharacters)
        #expect(presentation.hiddenCharacterWarning.contains("3"))
    }
}
