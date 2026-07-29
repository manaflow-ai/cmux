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

    @Test("Synthetic notch defaults to the center of each display")
    func syntheticNotchHorizontalPositionDefaultsToCenter() {
        let appearance = DynamicNotchAppearance()

        #expect(
            appearance[.syntheticNotchHorizontalPosition] == .number(0.5)
        )
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
        #expect(
            DynamicNotchAppearance.decodeFromJSON([
                "syntheticNotchHorizontalPosition": 1.1,
            ]) == nil
        )
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

    @Test("Per-display positions validate, round-trip, and remove independently")
    func perDisplayPositions() {
        let first = "uuid:first"
        let second = "uuid:second"
        var positions: [String: String] = [:]

        positions = DynamicNotchDisplayPositionSettings.setting(
            0.2,
            for: first,
            in: positions
        )
        positions = DynamicNotchDisplayPositionSettings.setting(
            0.8,
            for: second,
            in: positions
        )

        #expect(
            DynamicNotchDisplayPositionSettings.position(
                for: first,
                in: positions
            ) == 0.2
        )
        #expect(
            DynamicNotchDisplayPositionSettings.position(
                for: second,
                in: positions
            ) == 0.8
        )
        #expect(
            DynamicNotchDisplayPositionSettings.setting(
                1.1,
                for: first,
                in: positions
            ) == positions
        )
        #expect(
            DynamicNotchDisplayPositionSettings.removing(
                displayKey: first,
                from: positions
            ) == [second: "0.8"]
        )
    }

    @Test("Per-display JSON positions reject booleans and invalid values")
    func perDisplayPositionJSONValidation() {
        #expect(
            DynamicNotchDisplayPositionSettings.serializedPositions(
                fromJSONObject: ["uuid:first": 0.25]
            ) == ["uuid:first": "0.25"]
        )
        #expect(
            DynamicNotchDisplayPositionSettings.serializedPositions(
                fromJSONObject: ["uuid:first": true]
            ) == nil
        )
        #expect(
            DynamicNotchDisplayPositionSettings.serializedPositions(
                fromJSONObject: ["uuid:first": -0.1]
            ) == nil
        )
    }
}

@Suite("Dynamic Notch delivery")
struct DynamicNotchDeliverySettingsTests {
    @Test("Boolean controls map to the existing delivery enum")
    func enabledStateUsesNotificationDeliveryMode() throws {
        let suiteName = "cmux.dynamicNotchDelivery.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(!DynamicNotchDeliverySettings.isEnabled(defaults: defaults))

        DynamicNotchDeliverySettings.setEnabled(true, defaults: defaults)
        #expect(DynamicNotchDeliverySettings.isEnabled(defaults: defaults))
        #expect(
            defaults.string(
                forKey: SettingCatalog().notifications.delivery.userDefaultsKey
            ) == NotificationDeliveryMode.dynamicNotch.rawValue
        )

        DynamicNotchDeliverySettings.setEnabled(false, defaults: defaults)
        #expect(!DynamicNotchDeliverySettings.isEnabled(defaults: defaults))
        #expect(
            defaults.string(
                forKey: SettingCatalog().notifications.delivery.userDefaultsKey
            ) == NotificationDeliveryMode.system.rawValue
        )
    }
}
