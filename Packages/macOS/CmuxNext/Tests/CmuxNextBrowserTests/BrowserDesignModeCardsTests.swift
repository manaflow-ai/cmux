import Foundation
import Testing
@testable import CmuxNextBrowser

/// Design mode's page messages (classic `BrowserDesignModeRuntime.js`) turned into the cards an
/// agent chat's composer shows: one per new highlight, none again for the same element.
@Suite struct BrowserDesignModeCardsTests {
    nonisolated static let page = URL(string: "https://example.com/pricing?plan=pro")!

    nonisolated static func element(_ selector: String, tag: String = "button", text: String = "Buy now",
                                    x: Double = 10, y: Double = 20) -> [String: Any] {
        [
            "selector": selector, "selectors": [selector, "main > \(tag)"], "xpath": "/html/body/main/\(tag)[1]",
            "tag_name": tag, "dom_snippet": "<\(tag) class=\"cta\">\(text)</\(tag)>", "text_content": text,
            "text_editable": true, "computed_styles": ["color": "rgb(0, 0, 0)", "font-size": "14px"],
            "react_components": ["PricingCard"], "react_prop_keys": ["plan"],
            "source_location": ["file": "src/PricingCard.tsx", "line": 42, "column": 7],
            "bounds": ["x": x, "y": y, "width": 120, "height": 32],
            "viewport": ["width": 1280, "height": 800, "scroll_x": 0, "scroll_y": 0],
            "color": "#0a84ff",
        ]
    }

    nonisolated static func message(_ selections: [[String: Any]]) -> Data {
        let snapshot: [String: Any] = [
            "revision": 3, "enabled": true, "selection": selections.last ?? NSNull(), "selections": selections,
            "edits": [], "css_diff": "",
        ]
        return try! JSONSerialization.data(withJSONObject: ["type": "snapshot", "snapshot": snapshot])
    }

    @Test func aNewHighlightMakesOneCard() throws {
        var cards = BrowserDesignModeCards()
        let made = cards.receive(Self.message([Self.element("#buy")]), pageURL: Self.page)
        let card = try #require(made.first)
        #expect(made.count == 1)
        #expect(card.name.contains("button"))
        #expect(card.name.contains("example.com"))
        #expect(card.text.contains("https://example.com/pricing?plan=pro"))
        #expect(card.text.contains("#buy"))
        #expect(card.text.contains("Buy now"))
        #expect(card.text.contains("PricingCard"))
        #expect(card.text.contains("src/PricingCard.tsx:42:7"))
        #expect(card.bounds == CGRect(x: 10, y: 20, width: 120, height: 32))
        #expect(card.viewportWidth == 1280)
        #expect(card.id.hasPrefix("design-"))
    }

    @Test func theSameHighlightIsNotSentTwice() {
        var cards = BrowserDesignModeCards()
        _ = cards.receive(Self.message([Self.element("#buy")]), pageURL: Self.page)
        // A scroll moves the bounds; the element is the same.
        #expect(cards.receive(Self.message([Self.element("#buy", y: 300)]), pageURL: Self.page).isEmpty)
    }

    @Test func onlyTheNewHighlightIsSent() {
        var cards = BrowserDesignModeCards()
        _ = cards.receive(Self.message([Self.element("#buy")]), pageURL: Self.page)
        let made = cards.receive(Self.message([Self.element("#buy"), Self.element("h1.title", tag: "h1", text: "Pricing")]),
                                 pageURL: Self.page)
        #expect(made.map(\.text).count == 1)
        #expect(made.first?.text.contains("h1.title") == true)
    }

    @Test func aHighlightRemovedAndMadeAgainIsSentAgain() {
        var cards = BrowserDesignModeCards()
        let first = cards.receive(Self.message([Self.element("#buy")]), pageURL: Self.page)
        _ = cards.receive(Self.message([]), pageURL: Self.page)
        let again = cards.receive(Self.message([Self.element("#buy")]), pageURL: Self.page)
        #expect(again.count == 1)
        // The same element keeps its card id, so the composer replaces its chip.
        #expect(again.first?.id == first.first?.id)
    }

    @Test func aDrawnRegionMakesACard() {
        var cards = BrowserDesignModeCards()
        let region: [String: Any] = [
            "selector": "@annotation(a1)", "selectors": [], "xpath": "", "tag_name": "region", "dom_snippet": "",
            "text_content": "", "text_editable": false, "computed_styles": [:],
            "bounds": ["x": 0, "y": 0, "width": 50, "height": 50],
            "viewport": ["width": 1280, "height": 800, "scroll_x": 0, "scroll_y": 0],
        ]
        let made = cards.receive(Self.message([region]), pageURL: Self.page)
        #expect(made.count == 1)
        #expect(made.first?.name.contains("region") == true)
    }

    @Test(arguments: [
        Data("not json".utf8),
        try! JSONSerialization.data(withJSONObject: ["type": "prompt_reset"]),
        try! JSONSerialization.data(withJSONObject: ["type": "snapshot", "snapshot": "nope"]),
    ])
    func otherMessagesMakeNoCard(_ data: Data) {
        var cards = BrowserDesignModeCards()
        #expect(cards.receive(data, pageURL: Self.page).isEmpty)
    }

    @Test func escapeInThePageAsksToLeave() {
        let data = try! JSONSerialization.data(withJSONObject: ["type": "exit_requested"])
        #expect(BrowserDesignModeCards.isExitRequest(data))
        #expect(!BrowserDesignModeCards.isExitRequest(Self.message([])))
    }
}
