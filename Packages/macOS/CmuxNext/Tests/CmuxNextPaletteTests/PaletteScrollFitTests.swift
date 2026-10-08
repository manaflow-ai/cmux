import AppKit
import Testing
@testable import CmuxNextPalette

/// Dogfood nxdog13, palette side: a result list that fits neither scrolls
/// nor rubber-bands; a long one bounces.
@MainActor @Suite struct PaletteScrollFitTests {
    func rows(_ count: Int) -> [PaletteResultSection] {
        let items = (0..<count).map { index in
            PaletteRow(item: PaletteItem(id: "i\(index)", title: "Item \(index)",
                                         primary: PaletteCommand(id: "run", title: "Run", effect: .perform {})),
                       highlights: [], score: 0)
        }
        return [PaletteResultSection(section: .results, rows: items)]
    }

    func list(height: CGFloat) -> PaletteListView {
        let list = PaletteListView(frame: NSRect(x: 0, y: 0, width: 600, height: height))
        list.layoutSubtreeIfNeeded()
        return list
    }

    @Test func aFewResultsDoNotBounce() {
        let list = list(height: 400)
        list.setSections(rows(3))
        list.layoutSubtreeIfNeeded()
        #expect(list.verticalScrollElasticity == .none)
    }

    @Test func manyResultsBounceAndAShorterListStopsAgain() {
        let list = list(height: 400)
        list.setSections(rows(200))
        list.layoutSubtreeIfNeeded()
        #expect(list.verticalScrollElasticity == .allowed)
        list.setSections(rows(2))
        list.layoutSubtreeIfNeeded()
        #expect(list.verticalScrollElasticity == .none)
    }
}
