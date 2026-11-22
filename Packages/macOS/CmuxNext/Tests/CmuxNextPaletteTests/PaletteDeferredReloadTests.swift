import CmuxNextActions
@testable import CmuxNextPalette
import Testing

/// A reload of the open root page keeps a hidden provider's Recent row as the page last read it.
/// A setting toggled from Recent on the root palette's empty query read its row again at once, but
/// the copy kept for the next open's first frame updated only when the empty query's rank landed.
/// When the setting's write landed first, its reload stood that older copy in, and the row flashed
/// its old On/Off until the read after the frame (tip run 42592595122,
/// PaletteSettingWriteTests.swift:165: "the row showed [false, true, false]").
/// The main actor does not yield between the run and the reload, so the order is exact, with no timing.
@MainActor
struct PaletteDeferredReloadTests {
    /// A hidden provider (the root page's settings) with one on/off row whose state it holds.
    @MainActor private final class Switch: PaletteProvider {
        let id = "switches"
        let showsItemsForEmptyQuery = false
        var isOn = false

        nonisolated deinit {}

        var immediateItems: [PaletteItem]? { [item] }
        func items() async -> [PaletteItem] { [item] }

        private var item: PaletteItem {
            var item = PaletteItem(
                id: "switch:focus-ring", title: "Focus Ring",
                primary: PaletteCommand(id: "toggle", title: "Toggle", symbol: "switch.2",
                                        effect: .performKeepingOpen { [weak self] in self?.isOn.toggle() }),
                frecencyKey: "switch:focus-ring"
            )
            item.toggleState = isOn
            return item
        }
    }

    private func shown(_ model: PaletteModel) -> PaletteItem? {
        model.rows.first { $0.id == "switch:focus-ring" }?.item
    }

    @Test func aReloadBeforeTheRankLandsShowsTheRowAsItWasLastRead() async throws {
        let provider = Switch()
        let model = PaletteModel(persistence: nil)
        defer { model.send(.close) }
        let page = PalettePageSpec(id: "root", title: "Commands", placeholder: "", providers: [provider], showsRecent: true)
        model.recordUse("switch:focus-ring")
        model.reset(to: page)
        await model.settle()
        let row = try #require(shown(model), "the row is not under Recent: \(model.rows.map(\.id))")
        #expect(row.toggleState == false)

        model.run(row.primary, of: row)
        #expect(provider.isOn)
        #expect(shown(model)?.toggleState == true, "the run reads its row again at once")
        // The write lands before the empty query's rank: the open page reloads.
        model.reload()
        #expect(shown(model)?.toggleState == true, "the reload showed the row's value from before the run")
        await model.settle()
        #expect(shown(model)?.toggleState == true)
    }
}
