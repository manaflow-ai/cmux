import CmuxNextActions
@testable import CmuxNextPalette
import Foundation
import Testing

/// state-audit P2: a palette search installs its page's index and ranks the
/// query in one searcher turn. Another caller of the shared searcher (a
/// `palette.query` for another scope, a superseded search) used to install
/// its own index between the two calls, so the search ranked the wrong page.
@MainActor
@Suite struct PaletteSearchReentrancyTests {
    func item(_ id: String, _ title: String) -> PaletteItem {
        PaletteItem(id: id, title: title, primary: PaletteCommand(id: "run", title: "Run", effect: .perform {}))
    }

    @Test func aSearchRanksItsOwnPageWhenAnotherIndexIsInstalledMeanwhile() async {
        let model = PaletteModel(persistence: InMemoryFrecencyPersistence())
        model.reset(to: PalettePageSpec(id: "root", title: "Commands", placeholder: "Search", providers: [
            StaticPaletteProvider(id: "static", items: [item("alpha", "Alpha Lamp"), item("beta", "Beta Desk")]),
        ]))
        model.query = "alpha"
        // The search starts and goes to the searcher.
        await Task.yield()
        // Another page's index lands on the shared searcher meanwhile.
        let other = (0..<8).map { item("other.\($0)", "Zebra \($0)") }
        await model.searcher.install(PaletteSearchIndex(items: other), version: 1_000_000)
        await model.settle()
        #expect(model.rows.map(\.id) == ["alpha"])
    }
}
