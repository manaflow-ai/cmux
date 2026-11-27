import AppKit
@testable import CmuxNextDaemon
@testable import CmuxNextHomeModel
@testable import CmuxNextHomeEngine
import Testing

/// Leo 2026-10-21 (#89): the Chief settings showed raw ids (`claude-sr2-pipe`,
/// `claude-opus-5-5`). Every harness and model shows by a name a person reads: an official
/// engine's title, a model's catalog name, else the id made readable; the raw id stays only in a
/// tooltip.
@MainActor @Suite struct ChiefNamesTests {
    /// The names rules run in Rust (`chief_settings.*`, cmux-home-rules `tests/chief_settings_ops.rs`
    /// covers them); this checks the Swift callers reach them through the FFI.
    @Test func theNamesRulesAnswerThroughTheFFI() {
        #expect("claude-opus-5-5".chiefModelName == "Claude Opus 5.5")
        #expect("claude-sr2-pipe".chiefHarnessName == "\(ChiefBackend.claude.title) (SR2 Pipe)")
        #expect(ChiefBackend.badge(for: "claude") == nil)
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
