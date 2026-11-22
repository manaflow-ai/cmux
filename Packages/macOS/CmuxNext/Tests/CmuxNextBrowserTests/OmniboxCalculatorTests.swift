@testable import CmuxNextBrowser
import Foundation
import Testing

/// The calculator row (R110 pair 3): arithmetic only, exact answers, a row
/// right under what-you-typed, and Enter or a click copies the answer
/// without navigating.
@MainActor
@Suite struct OmniboxCalculatorTests {
    @Test func arithmeticEvaluates() {
        let cases: [(String, Double)] = [
            ("2+2", 4), ("2 + 3 * 4", 14), ("(2+3)*4", 20), ("2^3^2", 512), ("-3+5", 2), ("10/4", 2.5), ("7 % 3", 1),
            ("6×7", 42), ("9÷3", 3), ("1.5*2", 3), ("2*-3", -6), ("((1))+1", 2),
        ]
        for (text, value) in cases {
            #expect(OmniboxCalculator.evaluate(text) == value, "\(text)")
        }
        for text in ["", "42", "-5", "hello", "2+", "(2+3", "2++", "1/0", "github.com", "3.4.5+1", "2 + x"] {
            #expect(OmniboxCalculator.evaluate(text) == nil, "\(text)")
        }
        #expect(OmniboxCalculator.format(4) == "4")
        #expect(OmniboxCalculator.format(1.0 / 3) == "0.3333333333")
        #expect(OmniboxCalculator.format(-2.5) == "-2.5")
    }

    @Test func theAnswerRowSitsUnderWhatYouTyped() async {
        let engine = OmniboxSuggestionEngine()
        let rows = await engine.suggestions(for: "12*12")
        #expect(rows.map(\.kind) == [.search, .answer])
        #expect(rows.last?.title == "= 144" && rows.last?.content == "144" && rows.last?.inlineCompletable == false)
        #expect(rows.last?.detail == Strings.calculatorCopyHint)
        engine.apply(OmniboxConfiguration(calculator: false))
        #expect(await engine.suggestions(for: "12*12").map(\.kind) == [.search])
        #expect(await engine.suggestions(for: "weather").allSatisfy { $0.kind != .answer })
    }

    @Test func enterAndClickCopyTheAnswerAndNeverNavigate() async {
        let engine = OmniboxSuggestionEngine()
        let rows = await engine.suggestions(for: "6*7")
        let sim = OmnibarSim()
        sim.focus()
        sim.type("6*7", settle: false)
        sim.send(.suggestions(generation: sim.queries.last?.generation ?? 0, rows: rows))
        sim.key(.down)
        #expect(sim.field.text == "42")
        sim.key(.enter(.currentTab))
        #expect(sim.effects.contains(.copyAnswer("42")))
        #expect(sim.ended.isEmpty)
        #expect(sim.state.phase == .editing)
        sim.send(.rowClick(row: 1, .currentTab))
        #expect(sim.effects.filter { $0 == .copyAnswer("42") }.count == 2)
        #expect(sim.ended.isEmpty)
    }
}
