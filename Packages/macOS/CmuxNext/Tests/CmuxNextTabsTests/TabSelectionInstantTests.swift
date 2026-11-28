import QuartzCore
@testable import CmuxNextTabs
import Testing

/// DOGFOOD-CALL L4: a tab switch shows the new tab's content in one frame,
/// so the strip's highlight must move in that same frame (as in Chrome),
/// not cross-fade over the following frames beside content that already
/// changed. Hover keeps its fade.
@MainActor
@Suite(.serialized)
struct TabSelectionInstantTests {
    private func animations(_ layer: CALayer) -> [String] {
        (layer.animationKeys() ?? []) + (layer.sublayers ?? []).flatMap(animations)
    }

    @Test func selectingATabMovesItsHighlightWithoutAFade() {
        let cell = TabCell(item: TabItem(id: TabID("a"), title: "zsh"))
        cell.isSelected = true
        #expect(animations(cell.layer).isEmpty, "selection animated: \(animations(cell.layer))")
        cell.isSelected = false
        #expect(animations(cell.layer).isEmpty, "deselection animated: \(animations(cell.layer))")
    }
}
