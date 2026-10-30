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
        #expect("claude-sr2-pipe".chiefHarnessName == "\(ChiefBackend.claude.title) (SR2 Pipe)")
        #expect("claude-cr".chiefHarnessName == "\(ChiefBackend.claude.title) (CodeRouter)")
        #expect("claude-sr".chiefHarnessName == "\(ChiefBackend.claude.title) (Subrouter)")
        // acpmux's built-in harnesses read by acpmux's own names (cmux-tui/crates/acpmux/harnesses).
        #expect("gemini".chiefHarnessName == "Gemini CLI")
        #expect("pi".chiefHarnessName == "Pi")
        #expect("opencode".chiefHarnessName == "OpenCode")
        #expect("aider".chiefHarnessName == "Aider")
        #expect("muse".chiefHarnessName == "Muse Code")
        #expect("codex_gpt".chiefHarnessName == "\(ChiefBackend.codex.title) (GPT)")
        #expect("".chiefHarnessName == "")
        // The shared title and the Home row's badge use it for every id that is not official.
        #expect(ChiefBackend.title(for: "claude-sr2-pipe") == "\(ChiefBackend.claude.title) (SR2 Pipe)")
        #expect(ChiefBackend.title(for: "unii") == ChiefBackend.unii.title)
        #expect(ChiefBackend.badge(for: "gemini") == "Gemini CLI")
        #expect(ChiefBackend.badge(for: "pi") == "Pi")
    }

    @Test func aModelIdReadsAsAName() {
        #expect("claude-opus-5-5".chiefModelName == "Claude Opus 5.5")
        #expect("claude-sonnet-4-5-20250929".chiefModelName == "Claude Sonnet 4.5")
        #expect("gpt-5.1-codex-max".chiefModelName == "GPT 5.1 Codex Max")
        #expect("opus[1m]".chiefModelName == "Opus (1M)")
        // A dated snapshot drops its date, written either way.
        #expect("gpt-4o-2024-08-06".chiefModelName == "GPT 4o")
        #expect("gpt-5-2025-08-07".chiefModelName == "GPT 5")
        // Three numbers that are no date (month 13) stay.
        #expect("foo-2024-13-01".chiefModelName == "Foo 2024 13.01")
        // Nor eight digits with no real month or day.
        #expect("foo-20241301".chiefModelName == "Foo 20241301")
        #expect("foo-20240132".chiefModelName == "Foo 20240132")
        #expect("foo-20240131".chiefModelName == "Foo")
        #expect("opus".chiefModelName == "Opus")
        #expect("".chiefModelName == "")
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

    /// A plan model acpmux named by its id reads by a name too; Claude Code's `opusplan` keeps its title.
    @Test func aPlanNamedByItsIdShowsByName() throws {
        let models = [ChiefEngineReport.Model(id: "foo-plan", name: "foo-plan"), ChiefEngineReport.Model(id: "opusplan", name: "opusplan")]
        let items = HomeChiefModelMenu(models: models, chosen: nil, recents: []).items
        #expect(try #require(items.first { $0.value == "foo-plan" }).title == "Foo Plan")
        #expect(try #require(items.first { $0.value == "opusplan" }).title == HomeEngineStrings.opusPlanTitle)
        #expect(!items.map(\.title).contains("foo-plan"))
    }

    /// A plan row's tooltip keeps the harness's name for it and the id it writes.
    @Test func aPlanRowsTooltipNamesItsId() throws {
        let items = HomeChiefModelMenu(models: [.init(id: "opusplan", name: "Opus Plan Mode")], chosen: nil, recents: []).items
        #expect(try #require(items.first { $0.value == "opusplan" }).detail == "Opus Plan Mode\nopusplan")
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

    /// A brain that says its harness is acpmux's own "default" reads as plain Default.
    @Test func aDefaultHarnessReadsAsPlainDefault() {
        var snapshot = HomeChiefSnapshot(harness: nil, model: nil, effort: nil, avatar: nil, turns: [])
        snapshot.effective = ChiefEngineReport.Engine(harness: "default", model: nil, effort: nil)
        #expect(HomeChiefEngineTitles(snapshot).defaultHarness == HomeEngineStrings.defaultValue)
    }

    /// What Default runs, offered by a row acpmux named by its id, reads by a name, not the id.
    @Test func defaultNamesAnOfferedModelNamedByItsIdByName() {
        var snapshot = HomeChiefSnapshot(harness: nil, model: nil, effort: nil, avatar: nil, turns: [])
        snapshot.effective = ChiefEngineReport.Engine(harness: "opencode", model: "kimi-k2", effort: nil)
        snapshot.models = [ChiefEngineReport.Model(id: "kimi-k2", name: "kimi-k2")]
        let titles = HomeChiefEngineTitles(snapshot)
        #expect(titles.defaultModel == String(format: HomeEngineStrings.defaultNamedFormat, "Kimi K2"))
    }

    /// A model row's tooltip is the id a pick writes, after the alias and its release share one
    /// row, beside the catalog's description when there is one.
    @Test func aModelRowsTooltipIsTheIdItWrites() throws {
        let models = HomeChiefModelMenuTests.claudeModels
        let alias = try #require(HomeChiefModelMenu(models: models, chosen: nil, recents: []).items.first { $0.title == "Opus 5.5" })
        #expect(alias.value == "opus")
        #expect(alias.detail == "opus")
        let pinned = try #require(HomeChiefModelMenu(models: models, chosen: "claude-opus-5-5", recents: []).items.first { $0.title == "Opus 5.5" })
        #expect(pinned.value == "claude-opus-5-5")
        #expect(pinned.detail == "claude-opus-5-5", "the release id, not the alias the row started from")
        let described = [ChiefEngineReport.Model(id: "kimi-k2", name: "Kimi K2", description: "Moonshot's open model")]
        let row = try #require(HomeChiefModelMenu(models: described, chosen: nil, recents: []).items.first)
        #expect(row.detail == "Moonshot's open model\nkimi-k2")
    }

    /// Two ids that read as one name (`claude-cr`, `claude-cr-`) stay two items, and the chosen one is selected.
    @Test func twoIdsWithOneNameStayTwoItems() {
        let home = FileManager.default.temporaryDirectory
        let view = HomeChiefSettingsView(muxHome: home, source: HomeChiefLocalEngine(files: HomeChiefFiles(muxHome: home), connection: { nil }))
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        let name = "claude-cr".chiefHarnessName
        view.fill(button, [(value: "claude-cr", title: name)], current: "claude-cr-", defaultTitle: "Default", title: { _ in name })
        #expect(button.numberOfItems == 3)
        #expect(button.selectedItem?.representedObject as? String == "claude-cr-")
        #expect(button.selectedItem?.toolTip == "claude-cr-")
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
