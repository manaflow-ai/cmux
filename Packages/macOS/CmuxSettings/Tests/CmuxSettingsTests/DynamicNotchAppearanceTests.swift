import Foundation
import Testing
@testable import CmuxSettings

@Suite("Dynamic Notch appearance")
struct DynamicNotchAppearanceTests {
    @Test("Built-in appearance contains every token default")
    func defaultsCoverEveryToken() {
        let appearance = DynamicNotchAppearance()

        #expect(appearance.isDefault)
        for token in DynamicNotchAppearanceToken.allCases {
            #expect(appearance[token] == token.defaultValue)
        }
    }

    @Test("Pointer reveal defaults to direct notch hover")
    func pointerRevealDefaultsToExactHitRegion() {
        let appearance = DynamicNotchAppearance()

        #expect(appearance[.pointerRevealDistance] == .number(0))
    }

    @Test("Scroll container is flush with the shell by default")
    func scrollContainerHorizontalPaddingDefaultsToZero() {
        let appearance = DynamicNotchAppearance()

        #expect(
            appearance[.scrollContainerHorizontalPadding] == .number(0)
        )
    }

    @Test("Notch shadow is disabled by default")
    func shadowDefaultsAreTransparent() {
        let appearance = DynamicNotchAppearance()

        #expect(appearance[.shadowOpacity] == .number(0))
        #expect(appearance[.hoverShadowOpacity] == .number(0))
    }

    @Test("Partial JSON merges over defaults and normalizes colors")
    func partialJSONMergesAndNormalizes() {
        let appearance = DynamicNotchAppearance.decodeFromJSON([
            "expandedWidth": 612,
            "showScrollIndicators": false,
            "accentColor": "0a84ff",
        ])

        #expect(appearance?[.expandedWidth] == .number(612))
        #expect(appearance?[.showScrollIndicators] == .boolean(false))
        #expect(appearance?[.accentColor] == .color(.hex("#0A84FF")))
        #expect(
            appearance?[.compactWidth]
                == DynamicNotchAppearanceToken.compactWidth.defaultValue
        )
    }

    @Test("Unknown, mistyped, and out-of-range values are rejected")
    func invalidValuesAreRejected() {
        #expect(DynamicNotchAppearance.decodeFromJSON(["unknown": 1]) == nil)
        #expect(DynamicNotchAppearance.decodeFromJSON(["expandedWidth": true]) == nil)
        #expect(DynamicNotchAppearance.decodeFromJSON(["expandedWidth": 299]) == nil)
        #expect(DynamicNotchAppearance.decodeFromJSON(["accentColor": "#XYZXYZ"]) == nil)
    }

    @Test("Direct CLI assignments override spec appearance")
    func commandLineAssignmentsWin() throws {
        let spec = try DynamicNotchAppearanceOverrides(jsonObject: [
            "expandedWidth": 500,
            "accentColor": "#112233",
        ])
        let direct = try DynamicNotchAppearanceOverrides(assignments: [
            "expandedWidth=640",
            "showScrollIndicators=false",
        ])
        let merged = spec.merging(direct)

        #expect(merged[.expandedWidth] == .number(640))
        #expect(merged[.accentColor] == .color(.hex("#112233")))
        #expect(merged[.showScrollIndicators] == .boolean(false))
    }

    @Test("UserDefaults serialization round-trips a complete appearance")
    func userDefaultsRoundTrip() {
        let original = DynamicNotchAppearance()
            .replacing(.number(700), for: .expandedWidth)
            .replacing(.color(.hex("#ABCDEF")), for: .shellBackgroundColor)

        let decoded = DynamicNotchAppearance.decodeFromUserDefaults(
            original.encodeForUserDefaults()
        )

        #expect(decoded == original)
    }

    @Test("Generated JSON Schema covers the exact public token set")
    func schemaCoversTokens() {
        let properties = DynamicNotchAppearanceOverrides
            .jsonSchemaObject["properties"] as? [String: Any]

        #expect(
            Set(properties?.keys ?? Dictionary<String, Any>().keys)
                == Set(DynamicNotchAppearanceToken.allCases.map(\.rawValue))
        )
    }
}
