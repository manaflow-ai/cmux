import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// Custom densities in cmux.json (`appearance.customDensities`, `appearance.customDensity`) and
/// the built-ins in `appearance.density` (plans/cmux-next/density-DESIGN.md; Lawrence
/// 2026-10-20: "make sure people can create their own custom densities").
struct CustomDensitySettingTests {
    private static let valid = Set(DensityPreset.allCases.map(\.rawValue))

    private static func parse(_ appearance: [String: JSONValue]) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(.object(["appearance": .object(appearance)]), validDensities: valid, validMetrics: [])
    }

    private static let tight = DensityTokens(id: "my-tight", name: "My Tight", basedOn: "compact", level: -0.25, spacing: 0.9,
                                             fontSize: 11.5, tokens: ["sidebarRowHeight": 22, "itemCornerRadius": 5])

    @Test func everyBuiltInIsAValidDensity() {
        for preset in DensityPreset.allCases {
            let snapshot = Self.parse(["density": .string(preset.rawValue)])
            #expect(snapshot.selectedDensity == preset.tokens)
            #expect(snapshot.diagnostics.isEmpty)
        }
        #expect(Self.parse([:]).selectedDensity == DensityPreset.cozy.tokens, "Default is the fresh-install density")
    }

    @Test func aCustomDensityRoundTrips() throws {
        let json = CustomDensitiesSetting.json(Self.tight)
        let back = try #require(CustomDensitiesSetting.density(from: json))
        #expect(back == Self.tight)
        let snapshot = Self.parse(["customDensities": .array([json]), "customDensity": .string("my-tight")])
        #expect(snapshot.diagnostics.isEmpty)
        #expect(snapshot.customDensities == [Self.tight])
        #expect(snapshot.selectedDensity == Self.tight)
        let again = Self.parse(["customDensities": .array(snapshot.customDensities.map(CustomDensitiesSetting.json))])
        #expect(again.customDensities == snapshot.customDensities)
    }

    @Test func theCustomDensityWinsOverTheBuiltIn() {
        let json = CustomDensitiesSetting.json(Self.tight)
        let snapshot = Self.parse(["density": .string("spacious"), "customDensities": .array([json]), "customDensity": .string("my-tight")])
        #expect(snapshot.selectedDensity == Self.tight)
    }

    @Test func anUnknownCustomIDFallsBackWithADiagnostic() {
        let snapshot = Self.parse(["density": .string("cozy"), "customDensity": .string("gone")])
        #expect(snapshot.selectedDensity == DensityPreset.cozy.tokens)
        #expect(snapshot.diagnostics.contains { $0.path == "appearance.customDensity" })
        let unknown = Self.parse(["density": .string("huge")])
        #expect(unknown.selectedDensity == DensityPreset.cozy.tokens)
        #expect(unknown.diagnostics.contains { $0.path == "appearance.density" })
    }

    @Test func badEntriesAreSkippedWithADiagnostic() {
        let entries: [JSONValue] = [
            .object(["id": .string("Bad Id"), "name": .string("x")]),
            .object(["id": .string("compact"), "name": .string("Shadow")]),
            CustomDensitiesSetting.json(Self.tight),
            CustomDensitiesSetting.json(Self.tight),
            .object(["id": .string("a"), "name": .string("A"), "level": .string("1")]),
        ]
        let snapshot = Self.parse(["customDensities": .array(entries)])
        #expect(snapshot.customDensities == [Self.tight])
        #expect(snapshot.diagnostics.count == 4)
    }

    @Test func theSettingsWriteCheckAgrees() throws {
        let list = try #require(SettingsSchema.descriptor(for: CustomDensitiesSetting.configPath))
        #expect(list.accepts(.array([CustomDensitiesSetting.json(Self.tight)])))
        #expect(list.accepts(.array([])))
        #expect(!list.accepts(.string("my-tight")))
        #expect(!list.accepts(.array([.object([:])])))
        let density = try #require(SettingsSchema.descriptor(for: DensitySetting.configPath))
        for preset in DensityPreset.allCases { #expect(density.accepts(.string(preset.rawValue))) }
        #expect(!density.accepts(.string("my-tight")), "a custom one is chosen by appearance.customDensity")
    }

    @Test func duplicateMakesAUniqueID() {
        let first = CustomDensitiesSetting.duplicate(DensityPreset.cozy.tokens, name: "My Tight", existing: [])
        #expect(first.id == "my-tight" && first.basedOn == "cozy" && first.level == 0.5)
        let second = CustomDensitiesSetting.duplicate(first, name: "My Tight", existing: [first])
        #expect(second.id == "my-tight-2" && second.basedOn == "cozy")
        #expect(CustomDensitiesSetting.uniqueID(for: "Compact", existing: []) == "compact-2", "never a built-in's id")
        #expect(CustomDensitiesSetting.uniqueID(for: "日本", existing: []) == "custom")
    }

    @Test func webPresetCopiesKeepTheNativeTokens() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/density-web-exports.json")
        let exports = try JSONDecoder().decode([JSONValue].self, from: Data(contentsOf: fixture))
        #expect(exports.count == DensityPreset.allCases.count)
        for (json, preset) in zip(exports, DensityPreset.allCases) {
            let copy = try #require(CustomDensitiesSetting.density(from: json))
            let snapshot = Self.parse(["customDensities": .array([json]), "customDensity": .string(copy.id)])
            #expect(snapshot.diagnostics.isEmpty)
            #expect(snapshot.selectedDensity.tokens == preset.tokens.tokens)
            #expect(abs(snapshot.selectedDensity.bodySize - preset.tokens.bodySize) < 0.000_001)
            let copiedTitle = try #require(snapshot.selectedDensity.fontToken("tabTitleSize"))
            let presetTitle = try #require(preset.tokens.fontToken("tabTitleSize"))
            #expect(abs(copiedTitle - presetTitle) < 0.000_001)
        }
    }

    @MainActor @Test func webExactSizeEditsReachTheNativeRowsAndTabs() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/density-web-edited.json")
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: fixture))
        let copy = try #require(CustomDensitiesSetting.density(from: json))
        let snapshot = Self.parse(["customDensities": .array([json]), "customDensity": .string(copy.id)])
        DensityTokens.$scoped.withValue(snapshot.selectedDensity) {
            let sidebar = SidebarRowTokens(density: .compact, textSize: .standard, base: SidebarRowTokens.current.base)
            #expect(sidebar.listRowHeight == 40)
            #expect(sidebar.listRowCornerRadius == 3)
            #expect(Metrics.tabHeight == 38)
            #expect(Metrics.chromeTabCornerRadius == 3)
            #expect(Metrics.tabIconSize == 20)
            #expect(Metrics.tabContentLeadingInset == 10.5)
        }
    }

    @MainActor @Test func presetCopiesAndEditedRowsKeepTheLiveIconInset() {
        for preset in DensityPreset.allCases {
            let copy = CustomDensitiesSetting.duplicate(preset.tokens, name: "My density", existing: [])
            let original = DensityTokens.$scoped.withValue(preset.tokens) { Metrics.tabContentLeadingInset }
            let copied = DensityTokens.$scoped.withValue(copy) { Metrics.tabContentLeadingInset }
            #expect(copied == original, "\(preset): duplicating a preset preserves its icon inset")
        }
        var edited = CustomDensitiesSetting.duplicate(DensityPreset.compact.tokens, name: "My density", existing: [])
        edited.tokens["tabHeight"] = 40
        edited.tokens["tabIconSize"] = 20
        DensityTokens.$scoped.withValue(edited) {
            #expect(Metrics.tabContentLeadingInset == 11.5)
        }
        edited.tokens["tabIconLeading"] = 13
        DensityTokens.$scoped.withValue(edited) {
            #expect(Metrics.tabContentLeadingInset == 13, "a custom explicit inset keeps its value")
            let store = TunableStore.shared
            let tunable = ChromeTunables.tabContentLeadingInset
            store.activate(file: nil)
            store.register([tunable.descriptor])
            let previous = store.override(tunable.key)
            defer { store.set(tunable.key, previous) }
            store.set(tunable.key, .number(5))
            #expect(Metrics.tabContentLeadingInset == 5, "the Chrome override wins over a custom inset")
        }
    }
}
