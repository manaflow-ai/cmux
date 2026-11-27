import Foundation
import Testing
@testable import CmuxNextBrowser

/// Part 2 of design mode (plans/cmux-next/design-mode-DESIGN.md): a highlight removed on the page
/// takes its card out of the composer, and a style or text edit on the selected element rides on
/// its card (sent again under the same id, so the chip is replaced).
@Suite struct BrowserDesignModeChangeTests {
    nonisolated static let page = URL(string: "https://example.com/")!

    nonisolated static func selection(_ selector: String) -> [String: Any] {
        [
            "selector": selector, "selectors": [selector], "xpath": "", "tag_name": "button", "dom_snippet": "",
            "text_content": "Buy", "text_editable": true, "computed_styles": [:],
            "bounds": ["x": 0, "y": 0, "width": 10, "height": 10],
            "viewport": ["width": 100, "height": 100, "scroll_x": 0, "scroll_y": 0],
        ]
    }

    nonisolated static func message(_ selectors: [String], edits: [[String: Any]] = [], css: String = "") throws -> Data {
        let selections = selectors.map(selection)
        return try JSONSerialization.data(withJSONObject: [
            "type": "snapshot",
            "snapshot": ["revision": 1, "enabled": true, "selections": selections, "edits": edits, "css_diff": css],
        ])
    }

    @Test func aRemovedHighlightTakesItsCardOut() throws {
        var cards = BrowserDesignModeCards()
        let added = cards.change(try Self.message(["#a", "#b"]), pageURL: Self.page).cards
        let change = cards.change(try Self.message(["#b"]), pageURL: Self.page)
        #expect(change.cards.isEmpty)
        #expect(change.removed == [try #require(added.first?.id)])
    }

    @Test func aStyleEditRidesOnTheSelectedCard() throws {
        var cards = BrowserDesignModeCards()
        let first = try #require(cards.change(try Self.message(["#a"]), pageURL: Self.page).cards.first)
        let css = "#a {\n-  color: <unset>;\n+  color: red;\n}"
        let edits: [[String: Any]] = [["id": "e1", "kind": "style", "property": "color", "original_value": "", "value": "red"]]
        let change = cards.change(try Self.message(["#a"], edits: edits, css: css), pageURL: Self.page)
        let edited = try #require(change.cards.first)
        #expect(edited.id == first.id)
        #expect(edited.text.contains("+  color: red;"))
        #expect(change.removed.isEmpty)
        // The same edits again send nothing.
        #expect(cards.change(try Self.message(["#a"], edits: edits, css: css), pageURL: Self.page).cards.isEmpty)
    }

    @Test func aTextEditRidesOnTheSelectedCard() throws {
        var cards = BrowserDesignModeCards()
        _ = cards.change(try Self.message(["#a"]), pageURL: Self.page)
        let edits: [[String: Any]] = [["id": "t", "kind": "text", "property": "text-content", "original_value": "Buy", "value": "Buy now"]]
        let edited = try #require(cards.change(try Self.message(["#a"], edits: edits), pageURL: Self.page).cards.first)
        #expect(edited.text.contains("Text changed from \"Buy\" to \"Buy now\""))
    }

    @Test func designModeOffRemovesEveryCard() throws {
        var cards = BrowserDesignModeCards()
        let added = cards.change(try Self.message(["#a", "#b"]), pageURL: Self.page).cards
        #expect(Set(cards.removeAll()) == Set(added.map(\.id)))
    }
}
