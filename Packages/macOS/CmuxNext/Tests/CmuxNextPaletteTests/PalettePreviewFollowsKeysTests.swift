import AppKit
import CmuxNextActions
@testable import CmuxNextPalette
import Testing

/// A live-preview page (a theme or font picker) previews the row Return
/// would choose once a key moved the selection: a pointer resting over
/// another row, or a row a keyboard scroll slid under it, no longer wins.
/// Before, Down twice with the pointer over row e previewed e while Return
/// wrote c (QA spree 2026-10-21). Moving the pointer gives it back.
@MainActor
@Suite(.paletteRanker)
struct PalettePreviewFollowsKeysTests {
    private static func row(_ id: String) -> PaletteItem {
        PaletteItem(id: id, title: id, primary: PaletteCommand(id: "pick", title: "Pick", symbol: "return", effect: .perform {}))
    }

    final class Previews { var ids: [String?] = [] }

    private static func picker(_ previews: Previews) async -> PaletteController {
        _ = NSApplication.shared
        let palette = PaletteController(registry: ActionRegistry.standard(), sources: PaletteSources(), frecencyPersistence: nil)
        palette.model.reset(to: PalettePageSpec(
            id: "picker", title: "Theme", placeholder: "",
            providers: [StaticPaletteProvider(id: "rows", items: ["a", "b", "c", "d", "e"].map(row))],
            keepsSectionOrder: true, onHighlight: { previews.ids.append($0?.id) }))
        await palette.model.settle()
        return palette
    }

    @Test func keysLeadThePreviewOverARestingPointer() async throws {
        let previews = Previews()
        let palette = await Self.picker(previews)
        defer { palette.hide() }
        let model = palette.model
        // The page opened on "a"; the pointer rests over "e".
        model.pointerMoved(over: "b")
        model.pointerMoved(over: "e")
        #expect(previews.ids.last == "e")
        model.handle(.moveDown)
        model.handle(.moveDown)
        let selected = try #require(model.selectedRowID)
        #expect(selected != "e")
        #expect(previews.ids.last == selected, "previewing \(String(describing: previews.ids.last)) while Return picks \(selected)")
        // A keyboard scroll re-hit-tests hover: still the selection.
        model.hover("d")
        #expect(previews.ids.last == selected)
    }

    @Test func movingThePointerLeadsThePreviewAgain() async {
        let previews = Previews()
        let palette = await Self.picker(previews)
        defer { palette.hide() }
        palette.model.handle(.moveDown)
        palette.model.pointerMoved(over: "d")
        #expect(previews.ids.last == "d")
    }
}
