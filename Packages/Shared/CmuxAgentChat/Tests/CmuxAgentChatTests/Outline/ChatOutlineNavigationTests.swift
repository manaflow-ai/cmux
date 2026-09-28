import CmuxAgentChat
import Testing

@Suite("Chat outline navigator")
struct ChatOutlineNavigatorTests {
    // Prompts at rows 10, 50, (unanchored), 120.
    private let navigator = ChatOutlineNavigator(anchorRows: [10, 50, nil, 120])

    @Test("the current turn is the last prompt at or above the viewport's upper third")
    func currentTurn() {
        #expect(navigator.currentIndex(viewportTop: 0, viewportRows: 24) == nil)
        #expect(navigator.currentIndex(viewportTop: 9, viewportRows: 24) == 0)
        #expect(navigator.currentIndex(viewportTop: 45, viewportRows: 24) == 1)
        #expect(navigator.currentIndex(viewportTop: 100, viewportRows: 24) == 1)
        #expect(navigator.currentIndex(viewportTop: 119, viewportRows: 24) == 3)
    }

    @Test("next skips unanchored prompts and stops at the last one")
    func nextTarget() {
        #expect(navigator.nextTarget(viewportTop: 0, viewportRows: 24) == 0)
        #expect(navigator.nextTarget(viewportTop: 49, viewportRows: 24) == 3)
        #expect(navigator.nextTarget(viewportTop: 119, viewportRows: 24) == nil)
    }

    @Test("previous returns to the current prompt first when it scrolled off the top")
    func previousTarget() {
        #expect(navigator.previousTarget(viewportTop: 49, viewportRows: 24) == 0)
        #expect(navigator.previousTarget(viewportTop: 100, viewportRows: 24) == 1)
        #expect(navigator.previousTarget(viewportTop: 119, viewportRows: 24) == 1)
        #expect(navigator.previousTarget(viewportTop: 9, viewportRows: 24) == nil)
        #expect(navigator.previousTarget(viewportTop: 0, viewportRows: 3) == nil)
    }
}

@Suite("Chat outline rail layout")
struct ChatOutlineRailLayoutTests {
    @Test("few turns keep the preferred spacing, centered")
    func fewTurnsCentered() {
        let layout = ChatOutlineRailLayout(count: 3, height: 200)

        #expect(layout.spacing == ChatOutlineRailLayout.preferredSpacing)
        #expect(layout.y(for: 1) == 100)
        #expect(layout.drawnIndices(highlighted: nil) == [0, 1, 2])
        #expect(layout.index(atY: 100) == 1)
        #expect(layout.index(atY: 106) == 2)
        #expect(layout.index(atY: 10) == nil)
    }

    @Test("hundreds of turns compress, draw a subset, and still hover every turn")
    func manyTurnsCompress() {
        let layout = ChatOutlineRailLayout(count: 600, height: 624)
        // 600 turns over 600 usable points.
        #expect(layout.spacing < 1.01)
        #expect(layout.y(for: 0) >= ChatOutlineRailLayout.verticalInset - 0.01)
        #expect(layout.y(for: 599) <= 624 - ChatOutlineRailLayout.verticalInset + 0.01)

        let drawn = layout.drawnIndices(highlighted: 301)
        #expect(layout.drawStride == 3)
        #expect(drawn.contains(301))
        #expect(drawn.last == 599)
        #expect(drawn.count <= 600 / 3 + 2)

        let hovered = Set((0..<600).compactMap { layout.index(atY: layout.y(for: $0)) })
        #expect(hovered.count == 600)
    }

    @Test("a single turn sits in the middle")
    func singleTurn() {
        let layout = ChatOutlineRailLayout(count: 1, height: 100)

        #expect(layout.y(for: 0) == 50)
        #expect(layout.index(atY: 52) == 0)
    }
}
