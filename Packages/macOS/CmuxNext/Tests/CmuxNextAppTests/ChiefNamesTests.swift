import AppKit
@testable import CmuxNextDaemon
@testable import CmuxNextHome
@testable import CmuxNextHomeEngine
import Testing

/// Leo 2026-10-21 (#89): the Chief settings showed raw ids (`claude-sr2-pipe`,
/// `claude-opus-5-5`). Every harness and model shows by a name a person reads: an official
/// engine's title, a model's catalog name, else the id made readable; the raw id stays only in a
/// tooltip.
@MainActor @Suite struct ChiefNamesTests {
    @Test func aHarnessIdReadsAsItsEngineAndRoute() {
        #expect(ChiefNames.harness("claude-sr2-pipe") == "\(ChiefBackend.claude.title) (SR2 Pipe)")
        #expect(ChiefNames.harness("claude-cr") == "\(ChiefBackend.claude.title) (CodeRouter)")
        #expect(ChiefNames.harness("claude-sr") == "\(ChiefBackend.claude.title) (Subrouter)")
        #expect(ChiefNames.harness("gemini") == "Gemini")
        #expect(ChiefNames.harness("codex_gpt") == "\(ChiefBackend.codex.title) (GPT)")
        #expect(ChiefNames.harness("") == "")
        // The shared title and the Home row's badge use it for every id that is not official.
        #expect(ChiefBackend.title(for: "claude-sr2-pipe") == "\(ChiefBackend.claude.title) (SR2 Pipe)")
        #expect(ChiefBackend.title(for: "unii") == ChiefBackend.unii.title)
        #expect(ChiefBackend.badge(for: "gemini") == "Gemini")
    }

    @Test func aModelIdReadsAsAName() {
        #expect(ChiefNames.model("claude-opus-5-5") == "Claude Opus 5.5")
        #expect(ChiefNames.model("claude-sonnet-4-5-20250929") == "Claude Sonnet 4.5")
        #expect(ChiefNames.model("gpt-5.1-codex-max") == "GPT 5.1 Codex Max")
        #expect(ChiefNames.model("opus[1m]") == "Opus (1M)")
        #expect(ChiefNames.model("opus") == "Opus")
        #expect(ChiefNames.model("") == "")
    }

    /// A model the catalog names reads by its catalog name; one it does not, by its id made readable.
    @Test func aModelReadsByItsCatalogNameFirst() {
        let models = HomeChiefModelMenuTests.claudeModels
        #expect(HomeChiefModelMenu.name(of: "claude-opus-5-5", in: models) == "Opus 5.5")
        // An alias reads as the release it runs, with its context variant.
        #expect(HomeChiefModelMenu.name(of: "opus", in: models) == "Opus 5.5")
        #expect(HomeChiefModelMenu.name(of: "opus[1m]", in: models) == String(format: HomeEngineStrings.contextVariantFormat, "Opus 5.5", "1M"))
        #expect(HomeChiefModelMenu.name(of: "claude-opus-3-7", in: models) == "Claude Opus 3.7")
        // acpmux named it by its id: still a name.
        #expect(HomeChiefModelMenu.name(of: "kimi-k2", in: [.init(id: "kimi-k2", name: "kimi-k2")]) == "Kimi K2")
    }

    /// A chosen model the harness does not offer (set from the CLI) shows by a name, with its id
    /// as the row's tooltip.
    @Test func aChosenModelTheHarnessDoesNotOfferShowsByName() throws {
        let menu = HomeChiefModelMenu(models: HomeChiefModelMenuTests.claudeModels, chosen: "claude-opus-3-7", recents: [])
        let row = try #require(menu.items.first { $0.value == "claude-opus-3-7" })
        #expect(row.title == "Claude Opus 3.7")
        #expect(row.detail == "claude-opus-3-7")
    }

    /// What Default runs, when the catalog does not name it, reads by a name too.
    @Test func defaultNamesAnUncataloguedModelByName() {
        var snapshot = HomeChiefSnapshot(harness: nil, model: nil, effort: nil, avatar: nil, turns: [])
        snapshot.effective = ChiefEngineReport.Engine(harness: "claude-sr2-pipe", model: "claude-opus-5-5", effort: nil)
        let titles = HomeChiefEngineTitles(snapshot)
        #expect(titles.defaultModel == String(format: HomeEngineStrings.defaultNamedFormat, "Claude Opus 5.5"))
        #expect(titles.defaultHarness == String(format: HomeEngineStrings.defaultNamedFormat, "\(ChiefBackend.claude.title) (SR2 Pipe)"))
    }

    /// The Backend popup shows a chosen route by name and keeps its id in the item's tooltip.
    @Test func theBackendPopupShowsAChosenRouteByName() {
        let home = FileManager.default.temporaryDirectory
        let view = HomeChiefSettingsView(muxHome: home, source: HomeChiefLocalEngine(files: HomeChiefFiles(muxHome: home), connection: { nil }))
        view.show(HomeChiefSnapshot(harness: "claude-sr2-pipe", model: nil, effort: nil, avatar: nil, turns: []))
        #expect(view.harness.selectedItem?.title == "\(ChiefBackend.claude.title) (SR2 Pipe)")
        #expect(view.harness.selectedItem?.toolTip == "claude-sr2-pipe")
        #expect(!view.harness.itemTitles.contains("claude-sr2-pipe"))
    }
}
