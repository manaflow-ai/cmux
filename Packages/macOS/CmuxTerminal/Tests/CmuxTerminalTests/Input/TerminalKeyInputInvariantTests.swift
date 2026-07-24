import Testing
@testable import CmuxTerminal

@Suite struct TerminalKeyInputInvariantTests {
    private let planner = TerminalKeyInputPlanner()

    /// Exhausts every finite control-flow input to the planner against a
    /// test-only transcription of Ghostty's AppKit routing contract.
    @Test func matchesGhosttyAcrossCompleteControlStateSpace() {
        let booleans = [false, true]
        let committedTextVariants = [
            [],
            [""],
            ["\u{0008}"],
            ["opaque"],
            ["opaque", "👨🏽‍💻"],
        ]
        let textVariants: [String?] = [
            nil,
            "",
            "\u{0008}",
            "opaque",
            "a\u{301}",
        ]
        var checkedTransitions = 0
        var mismatches: [String] = []

        for hadMarkedText in booleans {
            for hasMarkedText in booleans {
                for textInputConsumed in booleans {
                    for textInputCommandPerformed in booleans {
                        for replaysPhysicalKeyAfterPreeditCommit in booleans {
                            for committedText in committedTextVariants {
                                for translatedText in textVariants {
                                    for rawText in textVariants {
                                        let snapshot = TerminalKeyInputSnapshot(
                                            hadMarkedText: hadMarkedText,
                                            hasMarkedText: hasMarkedText,
                                            textInputConsumed: textInputConsumed,
                                            textInputCommandPerformed: textInputCommandPerformed,
                                            committedText: committedText,
                                            event: TerminalKeyInputEvent(
                                                translatedText: translatedText,
                                                rawText: rawText,
                                                replaysPhysicalKeyAfterPreeditCommit:
                                                    replaysPhysicalKeyAfterPreeditCommit
                                            )
                                        )
                                        checkedTransitions += 1

                                        if planner.actions(for: snapshot) != ghosttyReferenceActions(for: snapshot),
                                           mismatches.count < 10 {
                                            mismatches.append(
                                                "had=\(hadMarkedText) has=\(hasMarkedText) " +
                                                    "consumed=\(textInputConsumed) " +
                                                    "command=\(textInputCommandPerformed) " +
                                                    "replay=\(replaysPhysicalKeyAfterPreeditCommit) " +
                                                    "committed=\(committedText) " +
                                                    "translated=\(String(describing: translatedText)) " +
                                                    "raw=\(String(describing: rawText))"
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        #expect(checkedTransitions == 4_000)
        #expect(mismatches.isEmpty)
    }

    /// The planner must never classify printable input by script or language.
    /// This checks every valid Unicode scalar, including unassigned scalars,
    /// while retaining Ghostty's universal C0 control-input rule.
    @Test func everyUnicodeScalarUsesOnlyUniversalControlSemantics() {
        var checkedScalars = 0
        var mismatches: [String] = []

        for value in UInt32(0)...UInt32(0x10_FFFF) {
            guard let scalar = Unicode.Scalar(value) else { continue }
            let text = String(scalar)
            checkedScalars += 1

            let directActions = planner.actions(for: snapshot(
                translatedText: text,
                rawText: text
            ))
            if directActions != [.sendKey(text: text, composing: false)],
               mismatches.count < 10 {
                mismatches.append("direct U+\(String(value, radix: 16, uppercase: true))")
            }

            let committedActions = planner.actions(for: snapshot(
                hadMarkedText: true,
                committedText: [text],
                translatedText: nil,
                rawText: nil
            ))
            let expectedCommittedActions: [TerminalKeyInputAction] =
                value < 0x20 ? [] : [.sendCommittedText(text)]
            if committedActions != expectedCommittedActions,
               mismatches.count < 10 {
                mismatches.append("committed U+\(String(value, radix: 16, uppercase: true))")
            }
        }

        #expect(checkedScalars == 1_112_064)
        #expect(mismatches.isEmpty)
    }

    /// Scalar coverage alone does not cover combining sequences, emoji clusters,
    /// or bidirectional controls. Fixed-seed generation exercises arbitrary
    /// multi-scalar strings without turning failures into flaky tests.
    @Test func generatedUnicodeSequencesRemainOpaque() {
        var generator = DeterministicUnicodeGenerator(seed: 0x434D_5558)
        var mismatches: [String] = []

        for index in 0..<20_000 {
            let text = generator.nextPrintableString()
            let directActions = planner.actions(for: snapshot(
                translatedText: text,
                rawText: text
            ))
            let committedActions = planner.actions(for: snapshot(
                hadMarkedText: true,
                committedText: [text],
                translatedText: nil,
                rawText: nil
            ))

            if directActions != [.sendKey(text: text, composing: false)],
               mismatches.count < 10 {
                mismatches.append("direct sequence \(index)")
            }
            if committedActions != [.sendCommittedText(text)],
               mismatches.count < 10 {
                mismatches.append("committed sequence \(index)")
            }
        }

        #expect(mismatches.isEmpty)
    }

    // Reference behavior from Ghostty's SurfaceView_AppKit.keyDown, augmented
    // with AppKit's explicit consumption and command callbacks. Keeping this
    // imperative shape separate from the planner catches routing drift.
    private func ghosttyReferenceActions(
        for snapshot: TerminalKeyInputSnapshot
    ) -> [TerminalKeyInputAction] {
        let composing = snapshot.hadMarkedText || snapshot.hasMarkedText
        let committedText = snapshot.committedText.filter {
            !ghosttySuppressesControlText($0, composing: composing)
        }

        if snapshot.hadMarkedText, !snapshot.committedText.isEmpty {
            var actions = committedText.map(TerminalKeyInputAction.sendCommittedText)
            if snapshot.event.replaysPhysicalKeyAfterPreeditCommit {
                actions.append(.sendKey(text: nil, composing: false))
            }
            return actions
        }

        if !snapshot.committedText.isEmpty {
            var actions: [TerminalKeyInputAction] = committedText.map {
                .sendKey(text: $0, composing: false)
            }
            if snapshot.textInputCommandPerformed {
                actions.append(.sendKey(text: nil, composing: false))
            }
            return actions
        }

        if ghosttySuppressesControlText(snapshot.event.rawText, composing: composing) {
            return []
        }

        if snapshot.textInputCommandPerformed {
            return [.sendKey(text: nil, composing: false)]
        }

        if snapshot.textInputConsumed {
            return []
        }

        return [
            .sendKey(
                text: snapshot.event.translatedText,
                composing: composing
            ),
        ]
    }

    private func ghosttySuppressesControlText(
        _ text: String?,
        composing: Bool
    ) -> Bool {
        guard composing, let text else { return false }
        let scalars = text.unicodeScalars
        guard let scalar = scalars.first,
              scalars.index(after: scalars.startIndex) == scalars.endIndex else {
            return false
        }
        return scalar.value < 0x20
    }

    private func snapshot(
        hadMarkedText: Bool = false,
        hasMarkedText: Bool = false,
        textInputConsumed: Bool = false,
        textInputCommandPerformed: Bool = false,
        committedText: [String] = [],
        translatedText: String?,
        rawText: String?
    ) -> TerminalKeyInputSnapshot {
        TerminalKeyInputSnapshot(
            hadMarkedText: hadMarkedText,
            hasMarkedText: hasMarkedText,
            textInputConsumed: textInputConsumed,
            textInputCommandPerformed: textInputCommandPerformed,
            committedText: committedText,
            event: TerminalKeyInputEvent(
                translatedText: translatedText,
                rawText: rawText
            )
        )
    }
}
