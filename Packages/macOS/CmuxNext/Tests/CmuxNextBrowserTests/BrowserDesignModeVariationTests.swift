import Foundation
import Testing
@testable import CmuxNextBrowser

/// The variation gallery (scripts/cmux-next/design-variations.py) tags each tile
/// `data-testid="cmux-variation-<n>"` (its caption `cmux-variation-<n>-title`): highlighting a tile
/// in design mode is the pick, and its card tells the agent which variation the person chose.
/// The Chief's Home composer takes a card as files (``BrowserDesignModeCardFiles``).
@Suite struct BrowserDesignModeVariationTests {
    nonisolated static let gallery = URL(string: "file:///tmp/variations/index.html")!

    nonisolated static func message(selector: String, text: String) throws -> Data {
        let selection: [String: Any] = [
            "selector": selector, "selectors": [selector], "xpath": "", "tag_name": "figure", "dom_snippet": "",
            "text_content": text, "text_editable": false, "computed_styles": [:],
            "bounds": ["x": 0, "y": 0, "width": 300, "height": 200],
            "viewport": ["width": 1200, "height": 800, "scroll_x": 0, "scroll_y": 0],
        ]
        return try JSONSerialization.data(withJSONObject: [
            "type": "snapshot", "snapshot": ["revision": 1, "enabled": true, "selections": [selection], "edits": [], "css_diff": ""],
        ])
    }

    @Test(arguments: ["[data-testid=\"cmux-variation-2\"]", "[data-testid=\"cmux-variation-2-title\"]"])
    func highlightingATileIsAPick(_ selector: String) throws {
        var cards = BrowserDesignModeCards()
        let card = try #require(cards.receive(try Self.message(selector: selector, text: "Bold hero"), pageURL: Self.gallery).first)
        #expect(card.text.hasPrefix("Picked design variation 2: Bold hero"))
        #expect(card.pickedVariation == 2)
    }

    @Test func anOrdinaryElementIsNoPick() throws {
        var cards = BrowserDesignModeCards()
        let card = try #require(cards.receive(try Self.message(selector: "#buy", text: "Buy"), pageURL: Self.gallery).first)
        #expect(card.pickedVariation == nil)
        #expect(!card.text.contains("Picked design variation"))
    }

    @Test func aCardBecomesFilesForTheChiefComposer() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("design-files-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let card = BrowserDesignModeCard(id: "design-1", name: "Design: button · example.com", text: "Selector: #buy",
                                         bounds: .zero, viewportWidth: 0)
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let files = try BrowserDesignModeCardFiles(folder: folder).write(card, png: png)
        #expect(files.map(\.lastPathComponent) == ["Design button · example.com.txt", "Design button · example.com.png"])
        #expect(try String(contentsOf: files[0], encoding: .utf8) == "Selector: #buy")
        #expect(try Data(contentsOf: files[1]) == png)
        // Without a crop it is the text file only; a name with a slash stays one file.
        let slashed = BrowserDesignModeCard(id: "design-2", name: "Design: a/b", text: "t", bounds: .zero, viewportWidth: 0)
        let only = try BrowserDesignModeCardFiles(folder: folder).write(slashed, png: nil)
        #expect(only.map(\.lastPathComponent) == ["Design a-b.txt"])
    }
}
