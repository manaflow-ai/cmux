import Foundation
import QuartzCore
@testable import CmuxNextTabs
import Testing

/// The `tab.close` theme slot (schemas/theme/slots.json, TabCloseSlot.swift): a theme file's pick
/// reaches the tab's close glyph, and with no pick the tab draws the x it drew before slots.
@MainActor @Suite struct TabCloseSlotTests {
    /// schemas/theme/slots.json, from this file's place in the repo.
    static let schemaURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("schemas/theme/slots.json")

    @Test func theSchemaListsExactlyTheVariantsTheTabDraws() throws {
        let schema = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: Self.schemaURL)) as? [String: Any])
        let slots = try #require(schema["slots"] as? [[String: Any]])
        let entry = try #require(slots.first { $0["id"] as? String == TabCloseSlot.id })
        let variants = try #require(entry["variants"] as? [[String: Any]]).compactMap { $0["id"] as? String }
        #expect(variants == TabCloseSlot.allCases.map(\.rawValue))
        #expect(entry["defaultVariant"] as? String == TabCloseSlot.default.rawValue)
        let next = (schema["next"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        #expect(!next.contains(TabCloseSlot.id), "tab.close ships, so it is no longer a next slot")
    }

    @Test func noPickOrAPickThisBuildDoesNotShipDrawsTheDefault() {
        #expect(TabCloseSlot.variant(in: [:]) == .default)
        #expect(TabCloseSlot.variant(in: ["tab.close": "default"]) == .default)
        #expect(TabCloseSlot.variant(in: ["tab.close": "sparkles"]) == .default)
        #expect(TabCloseSlot.variant(in: ["chat.jumpToBottom": "nudge"]) == .default)
    }

    @Test func theDefaultDrawsTheXFromBeforeSlots() {
        for side in [CGFloat(6), 7.2, 9] {
            let box = CGRect(x: 0, y: 0, width: side, height: side)
            #expect(TabCloseSlot.default.glyphPath(in: box) == TabCell.closeGlyphPath(in: box))
        }
    }
}
