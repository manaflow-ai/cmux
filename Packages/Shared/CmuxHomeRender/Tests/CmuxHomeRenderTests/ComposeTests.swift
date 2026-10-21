import CoreGraphics
import Foundation
import Testing
@testable import CmuxHomeRender

@MainActor
@Suite struct ComposeTests {
    /// The field draws its glass on the first layout at any width (it was
    /// skipped at exactly the reference width).
    @Test(arguments: [628.0, 420.0])
    func fieldHasGlassAfterFirstLayout(width: Double) {
        let c = Fixtures.controller(width: CGFloat(width), height: 700)
        #expect(c.scene.compose.glass.contents != nil)
        #expect(c.fieldRect.width == CGFloat(width) - ComposeLayer.sideRoom)
        #expect(abs(c.fieldRect.maxY - (700 - ComposeLayer.bottomInset)) < 0.01)
    }

    /// The field grows a line per wrapped line (up to 8) and the transcript anchor rises with it.
    @Test func fieldGrowsWithItsText() {
        let c = Fixtures.controller(width: 628, height: 700)
        let anchor = c.scene.anchorY
        c.handle(.insertText("one\ntwo\nthree", replacing: nil))
        #expect(c.fieldRect.height == ComposeLayer.height(lines: 3) + 0.25)
        #expect(abs((anchor - c.scene.anchorY) - (ComposeLayer.height(lines: 3) - ComposeLayer.height(lines: 1))) < 0.01)
        c.handle(.insertText(String(repeating: "\nmore", count: 20), replacing: nil))
        #expect(c.fieldRect.height == ComposeLayer.height(lines: ComposeLayer.maxLines) + 0.25)
    }

    @Test func editorHandlesCompositionAndComposedCharacters() {
        var e = ComposeEditor()
        e.insert("ab")
        e.setMarked("か", selected: NSRange(location: 1, length: 0))
        #expect(e.text == "abか" && e.marked == NSRange(location: 2, length: 1))
        e.setMarked("かな", selected: NSRange(location: 2, length: 0))
        #expect(e.text == "abかな" && e.selection == NSRange(location: 4, length: 0))
        e.insert("仮名")
        #expect(e.text == "ab仮名" && e.marked == nil)
        e.insert("👍🏽")
        e.deleteBackward()
        #expect(e.text == "ab仮名")
        e.moveCaret(by: -1)
        #expect(e.selection == NSRange(location: 3, length: 0))
    }
}
