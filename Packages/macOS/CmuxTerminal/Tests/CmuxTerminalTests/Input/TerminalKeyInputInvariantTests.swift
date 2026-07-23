import Testing
@testable import CmuxTerminal

@Suite struct TerminalKeyInputInvariantTests {
    private let planner = TerminalKeyInputPlanner()

    /// Exhausts every finite control-flow input to the planner against a
    /// test-only transcription of Ghostty's AppKit routing contract.
    @Test func matchesGhosttyAcrossCompleteControlStateSpace() {
        let booleans = [false, true]
        let keys: [TerminalKeyInputKey] = [
            .arrowLeft,
            .arrowRight,
            .arrowUp,
            .arrowDown,
            .other,
        ]
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
                for inputSourceChanged in booleans {
                    for committedText in committedTextVariants {
                        for key in keys {
                            for hasModifier in booleans {
                                for translatedText in textVariants {
                                    for rawText in textVariants {
                                        let snapshot = TerminalKeyInputSnapshot(
                                            hadMarkedText: hadMarkedText,
                                            hasMarkedText: hasMarkedText,
                                            inputSourceChanged: inputSourceChanged,
                                            committedText: committedText,
                                            event: TerminalKeyInputEvent(
                                                key: key,
                                                hasModifier: hasModifier,
                                                translatedText: translatedText,
                                                rawText: rawText
                                            )
                                        )
                                        checkedTransitions += 1

                                        if planner.actions(for: snapshot) != ghosttyReferenceActions(for: snapshot),
                                           mismatches.count < 10 {
                                            mismatches.append(
                                                "had=\(hadMarkedText) has=\(hasMarkedText) " +
                                                    "sourceChanged=\(inputSourceChanged) key=\(key) " +
                                                    "modifier=\(hasModifier) committed=\(committedText) " +
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

        #expect(checkedTransitions == 10_000)
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

    // Reference behavior from Ghostty's SurfaceView_AppKit.keyDown. Keeping
    // this imperative shape separate from the planner catches routing drift.
    private func ghosttyReferenceActions(
        for snapshot: TerminalKeyInputSnapshot
    ) -> [TerminalKeyInputAction] {
        if snapshot.inputSourceChanged {
            return []
        }

        let composing = snapshot.hadMarkedText || snapshot.hasMarkedText
        let committedText = snapshot.committedText.filter {
            !ghosttySuppressesControlText($0, composing: composing)
        }

        if snapshot.hadMarkedText, !snapshot.committedText.isEmpty {
            var actions = committedText.map(TerminalKeyInputAction.sendCommittedText)
            switch snapshot.event.key {
            case .arrowDown, .arrowRight, .arrowUp:
                actions.append(.sendKey(text: nil, composing: false))
            case .arrowLeft where snapshot.event.hasModifier:
                actions.append(.sendKey(text: nil, composing: false))
            case .arrowLeft, .other:
                break
            }
            return actions
        }

        if !snapshot.committedText.isEmpty {
            return committedText.map {
                .sendKey(text: $0, composing: false)
            }
        }

        if ghosttySuppressesControlText(snapshot.event.rawText, composing: composing) {
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
        inputSourceChanged: Bool = false,
        committedText: [String] = [],
        key: TerminalKeyInputKey = .other,
        hasModifier: Bool = false,
        translatedText: String?,
        rawText: String?
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
                rawText: rawText
            )
        )
    }
}

private struct DeterministicUnicodeGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func nextPrintableString() -> String {
        let length = Int(next() % 16) + 1
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(length)

        while scalars.count < length {
            let value = UInt32(next() % 0x11_0000)
            guard value >= 0x20, let scalar = Unicode.Scalar(value) else {
                continue
            }
            scalars.append(scalar)
        }

        return String(scalars)
    }

    private mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
