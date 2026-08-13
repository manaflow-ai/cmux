import Testing
@testable import CmuxWorkspaces

@Suite("Agent context pressure detection")
struct AgentContextPressureDetectorTests {
    @Test("Claude's long-thread warning is detected across output chunks")
    func claudeLongThreadWarningAcrossChunks() {
        var detector = AgentContextPressureDetector(provider: .claudeCode)
        let first = "⚠ Heads up: Long threads and multiple compactions can cause the model to be less\n"
        let second = "accurate. Start a new thread when possible to keep threads small and targeted."

        #expect(detector.consume(first).isEmpty)
        let events = detector.consume(second)

        #expect(events.count == 1)
        #expect(events.first?.provider == .claudeCode)
        #expect(events.first?.signal == .longThreadWarning)
        #expect(detector.snapshot.isUnderPressure)
    }

    @Test("ANSI escapes and ordinary prose do not create a false positive")
    func ignoresAnsiAndOrdinaryProse() {
        var detector = AgentContextPressureDetector(provider: .claudeCode)
        let output = "\u{1b}[31mcontext\u{1b}[0m is a variable in this explanation\n"

        #expect(detector.consume(output).isEmpty)
        #expect(!detector.snapshot.isUnderPressure)
    }

    @Test("A context low-level phrase is not treated as a provider indicator")
    func ignoresContextLowLevelProse() {
        var detector = AgentContextPressureDetector(provider: .claudeCode)

        #expect(detector.consume("The context low-level API is documented here.\n").isEmpty)
        #expect(detector.consume("Keep the surrounding context low for this example.\n").isEmpty)
        #expect(!detector.snapshot.isUnderPressure)
    }

    @Test("Repeated Claude auto-compaction events raise pressure once the pattern repeats")
    func repeatedAutoCompaction() {
        var detector = AgentContextPressureDetector(provider: .claudeCode)

        let firstEvents = detector.consume("Auto-compacting conversation...\n")
        #expect(firstEvents.isEmpty)
        #expect(!detector.snapshot.isUnderPressure)
        #expect(detector.snapshot.occurrences[.repeatedAutoCompaction] == 1)
        let events = detector.consume("Auto-compacting conversation...\n")

        #expect(events.contains { $0.signal == .repeatedAutoCompaction })
        #expect(events.first?.occurrence == 2)
    }

    @Test("Whitespace split across PTY chunks does not break a marker")
    func whitespaceBoundaryIsPreserved() {
        var detector = AgentContextPressureDetector(provider: .claudeCode)

        #expect(detector.consume("Long threads and multiple compactions can cause the model to be less\n").isEmpty)
        let events = detector.consume("\n accurate. Start a new thread when possible to keep threads small and targeted.")

        #expect(events.contains { $0.signal == .longThreadWarning })
    }

    @Test("Codex context-low indicators use the Codex provider definition")
    func codexContextLow() {
        var detector = AgentContextPressureDetector(provider: .codex)

        let events = detector.consume("Context window is almost full; 8% remaining.\n")

        #expect(events.contains { $0.provider == .codex && $0.signal == .contextLow })
    }

    @Test("Codex recognizes the shared long-thread warning")
    func codexLongThreadWarning() {
        var detector = AgentContextPressureDetector(provider: .codex)

        let events = detector.consume(
            "Heads up: Long threads and multiple compactions can cause the model to be less accurate. " +
                "Start a new thread when possible to keep threads small and targeted.\n"
        )

        #expect(events.contains { $0.provider == .codex && $0.signal == .longThreadWarning })
    }

    @Test("Codex low remaining percentage is detected without flagging a healthy footer")
    func codexLowRemainingPercentage() {
        var detector = AgentContextPressureDetector(provider: .codex)

        #expect(detector.consume("95% context left\n").isEmpty)
        let events = detector.consume("5% context left\n")

        #expect(events.contains { $0.signal == .contextLow })
    }

    @Test("Ordinary Codex context-remaining status does not imply low context")
    func codexOrdinaryContextRemainingIsIgnored() {
        var detector = AgentContextPressureDetector(provider: .codex)

        let events = detector.consume("95% context remaining\n")

        #expect(events.isEmpty)
        #expect(!detector.snapshot.isUnderPressure)
    }

    @Test("Claude context-left percentage is detected when the percentage follows the label")
    func claudeTrailingContextPercentage() {
        var detector = AgentContextPressureDetector(provider: .claudeCode)

        let events = detector.consume("Context left until auto-compact: 8%\n")

        #expect(events.contains { $0.signal == .contextLow })
        #expect(events.first?.occurrence == 1)
    }

    @Test("A trailing low-context percentage split after its label is detected")
    func claudeTrailingContextPercentageAcrossChunks() {
        var detector = AgentContextPressureDetector(provider: .claudeCode)

        #expect(detector.consume("Context left until auto-compact: ").isEmpty)
        let events = detector.consume("8%\n")

        #expect(events.contains { $0.signal == .contextLow })
    }

    @Test("Claude's current auto-compact footer and warning are detected")
    func claudeCurrentAutoCompactIndicators() {
        var footerDetector = AgentContextPressureDetector(provider: .claudeCode)
        var warningDetector = AgentContextPressureDetector(provider: .claudeCode)

        #expect(
            footerDetector.consume("8% until auto-compact\n")
                .contains { $0.signal == .contextLow }
        )
        #expect(
            warningDetector.consume(
                "Autocompact will trigger soon, which discards older messages. " +
                    "Use /compact now to control what gets kept.\n"
            ).contains { $0.signal == .contextLow }
        )
    }

    @Test("Percentage parsing does not treat ordinary prose as a pressure footer")
    func contextPercentageOrdinaryProseIsIgnored() {
        var detector = AgentContextPressureDetector(provider: .claudeCode)

        let events = detector.consume("The context left in this explanation is 5% of the article.\n")

        #expect(events.isEmpty)
        #expect(!detector.snapshot.isUnderPressure)
    }

    @Test("A detector can be reset after a completed recovery action")
    func resetClearsPressure() {
        var detector = AgentContextPressureDetector(provider: .claudeCode)
        _ = detector.consume("Context window is almost full.\n")

        detector.reset()

        #expect(!detector.snapshot.isUnderPressure)
        #expect(detector.snapshot.detectedSignals.isEmpty)
    }
}
