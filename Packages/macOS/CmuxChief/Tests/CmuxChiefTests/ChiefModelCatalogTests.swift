@testable import CmuxChief
import Testing

/// The picker's catalog against acpmux's `models-v1.json` (feat-cmux-next, snapshot
/// 2026-10-13), and an unknown model's failure as the user reads it.
@Suite struct ChiefModelCatalogTests {
    /// (harness, model id, the efforts its catalog row lists). Update with ChiefModelCatalog.swift.
    static let rows: [(ChiefHarness, String, [String])] = [
        (.claude, "claude-opus-5-5", ["low", "medium", "high", "xhigh", "max"]),
        (.claude, "claude-sonnet-5-5", ["low", "medium", "high", "xhigh", "max"]),
        (.claude, "claude-haiku-5-5", ["low", "medium", "high", "xhigh", "max"]),
        (.claude, "claude-fable-5-1", ["low", "medium", "high", "xhigh", "max"]),
        (.codex, "gpt-6.1-sol", ["low", "medium", "high", "xhigh", "max"]),
        (.codex, "gpt-6-sol", ["low", "medium", "high", "xhigh", "max"]),
        (.codex, "gpt-6-astra", ["low", "medium", "high", "xhigh", "max"]),
        (.codex, "gpt-6-luna", ["low", "medium", "high", "xhigh", "max"]),
        (.codex, "gpt-5.6-sol", ["low", "medium", "high", "xhigh", "max"]),
        (.codex, "gpt-5.5", ["low", "medium", "high", "xhigh"]),
    ]

    @Test func everyModelOffersExactlyTheEffortsItsRowLists() {
        for harness in ChiefHarness.allCases {
            #expect(harness.models.map(\.id) == Self.rows.filter { $0.0 == harness }.map(\.1), "\(harness)")
        }
        for (harness, model, efforts) in Self.rows {
            #expect(harness.efforts(for: model).map(\.id) == efforts, "\(model)")
        }
        // Every level the picker offers is one `claude --effort` takes.
        let cli: Set<String> = ["low", "medium", "high", "xhigh", "max"]
        #expect(ChiefHarness.allCases.flatMap(\.models).allSatisfy { Set($0.efforts.map(\.id)).isSubset(of: cli) })
    }

    @Test func anUnlistedModelKeepsTheEffortPickerAtItsDefault() {
        // Custom model ids remain valid CLI inputs, but the catalog cannot
        // safely claim which explicit effort flags they accept.
        #expect(ChiefHarness.claude.efforts(for: "claude-future-6") == [])
        #expect(ChiefHarness.codex.efforts(for: "gpt-future") == [])
    }

    @Test(arguments: [
        "There's an issue with the selected model (claude-opus-9). It may not exist or you may not have access to it. Run --model to pick a different model.",
        #"API Error: 404 {"type":"error","error":{"type":"not_found_error","message":"model: claude-opus-9"}}"#,
        "[claude-code:unrecognized_model] {\"model\":\"claude-opus-9\"}",
        "The model `claude-opus-9` does not exist or you do not have access to it.",
        "The 'claude-opus-9' model is not supported when using Codex with a ChatGPT account.",
        "model_not_found",
    ])
    func anUnknownModelPointsAtChiefSettings(message: String) {
        let text = ChiefHarness.claude.failureMessage(message, model: "claude-opus-9")
        #expect(text == ChiefText.unknownModel("claude-opus-9", harness: "Claude Code"))
        #expect(text.contains("Chief Settings"))
        #expect(text.contains("claude-opus-9"))
    }

    @Test func otherFailuresKeepTheirText() {
        for message in ["Claude Code stopped: too many turns.", "Rate limit reached. Try again later.",
                        "The file was not found: /tmp/x", "Codex failed."] {
            #expect(ChiefHarness.codex.failureMessage(message, model: "gpt-6.1-sol") == message)
        }
    }
}
