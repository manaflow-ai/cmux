@testable import CmuxNextApps
import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing

/// A look's particles glyph reaches a sidebar row (Leo, 2026-11-19: "the dots and the way it moves
/// changes a lot"): `cmux.sidebar.rows/1` `indicator` as `{choreography, trigger}` carries the
/// document and trigger into the row's decoration; `"glyph"` and `{choreography: "glyph"}` name the
/// look's `agentPane.display.thinking.glyph`; a string style still sets the indicator style. The
/// settings write check takes a document of the schema and refuses the rest (Rust's validator is the
/// full check, on every write through the settings owner).
struct SidebarRowGlyphTests {
    private static let lone: AppJSON = .object([
        "$schema": "cmux.particles/1",
        "particle": .object(["size": 3, "max": 1]),
        "phases": .object(["lone": .object(["duration": 400, "frames": .array([.object(["at": 0, "dots": .array([.array([0, 0, 0.7])])])])])]),
    ])

    private static func decorations(_ indicator: AppJSON) -> [String: SidebarRowDecoration] {
        var scene = AppScene()
        scene.apply([.create(id: "g", type: "Group", props: ["row": "w1", "indicator": indicator]), .root(id: "g")])
        return SidebarCustomizationService.decorations(scene)
    }

    @Test func aRowsOwnDocumentAndTriggerReachTheDecoration() throws {
        let decoration = try #require(Self.decorations(.object(["choreography": Self.lone, "trigger": "execute"]))["w1"])
        let glyph = try #require(decoration.glyph)
        #expect(glyph.trigger == "execute")
        let document = try AppJSON.parse(try #require(glyph.document))
        #expect(document == Self.lone)
        #expect(AppSceneChoreography(json: document) != nil)
        #expect(decoration.indicator == nil)
    }

    @Test func glyphNamesTheLooksSetting() throws {
        #expect(Self.decorations("glyph")["w1"]?.glyph == SidebarRowGlyph())
        #expect(Self.decorations(.object(["choreography": "glyph", "trigger": "read"]))["w1"]?.glyph == SidebarRowGlyph(trigger: "read"))
        // A refused document (the host sends null) and a style keep the indicator.
        #expect(Self.decorations(.object(["choreography": .null]))["w1"]?.glyph == nil)
        let styled = try #require(Self.decorations("dot")["w1"])
        #expect(styled.glyph == nil)
        #expect(styled.indicator == .dot)
    }

    @Test func theRowCarriesTheGlyphToItsIndicator() {
        let glyph = SidebarRowGlyph(document: nil, trigger: "execute")
        let decoration = SidebarRowDecoration(glyph: glyph)
        #expect(decoration.glyph == glyph)
    }

    @Test func theSettingsWriteCheckTakesADocumentOfTheSchema() throws {
        let row = try #require(SettingsSchema.descriptor(for: ThinkingGlyphSetting().configPath))
        let lone: JSONValue = .object([
            "$schema": .string("cmux.particles/1"),
            "particle": .object(["size": .number(3)]),
            "phases": .object(["lone": .object(["duration": .number(400), "frames": .array([])])]),
        ])
        #expect(row.accepts(lone))
        #expect(!row.accepts(.string("thinking-glyph.json")))
        #expect(!row.accepts(.object(["$schema": .string("cmux.particles/2")])))
        #expect(!row.accepts(.object(["$schema": .string("cmux.particles/1"), "particle": .object(["size": .number(3)]), "phases": .object([:])])))
    }
}
