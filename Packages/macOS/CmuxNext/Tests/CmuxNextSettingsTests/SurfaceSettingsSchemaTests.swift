@testable import CmuxNextSettings
import Foundation
import Testing

/// Appearance > Surfaces (Lawrence R55): a color row and an opacity row for
/// each of twelve surfaces (including internal pages, split dividers and the diff viewer), both optional overrides of the window's own color
/// and opacity, in the shape the Settings lead and the coordinator agreed.
@Suite struct SurfaceSettingsSchemaTests {
    static let surfaces = ["sidebar", "tabBar", "terminal", "agentPane", "settings", "newTabPage", "home", "browserChrome", "internalPage", "splitDivider", "docks", "diff", "markdown", "editor"]

    static func path(_ surface: String, _ field: String) -> [String] { ["appearance", "surfaces", surface, field] }

    static func diagnostics(_ value: JSONValue, at path: [String]) -> [SettingsDiagnostic] {
        let root = SettingsSchemaTests.setting(value, at: path, in: .object([:]))
        return CmuxConfigSnapshot.parse(root, validDensities: SettingsSchemaTests.densities, validMetrics: [])
            .diagnostics.filter { $0.path == path.joined(separator: ".") }
    }

    @Test func twentyEightRowsInAppearanceSurfaces() throws {
        let rows = SettingsSchema.all.filter { $0.path.starts(with: ["appearance", "surfaces"]) }
        #expect(rows.count == 28)
        for surface in Self.surfaces {
            for field in ["color", "opacity"] {
                let row = try #require(SettingsSchema.descriptor(for: Self.path(surface, field)), "\(surface).\(field)")
                #expect(row.section == .appearance)
                #expect(row.textKeys.group == "settings.group.surfaces")
                #expect(row.textKeys.title == "settings.appearance.surfaces.\(surface).\(field)")
                #expect(row.defaultValue == nil, "absent key = default")
                #expect(SettingsSchema.agentSettable(row) == true)
                #expect(!SettingsSchema.keptOnResetAll.contains(row.path))
            }
        }
    }

    @Test func colorRowsAreColorsThatDefaultToTheWindow() throws {
        for surface in Self.surfaces {
            let row = try #require(SettingsSchema.descriptor(for: Self.path(surface, "color")))
            #expect(row.kind == .color)
            #expect(row.textKeys.defaultLabel == "settings.default.sameAsWindow")
            #expect(row.defaultLabel == "Same as window")
            for good in ["#1E1E2E", "#1E1E2E80"] as [JSONValue] {
                #expect(row.accepts(good))
                #expect(Self.diagnostics(good, at: row.path).isEmpty, "\(row.id) = \(good)")
            }
            for bad in ["surface", "red", 7] as [JSONValue] {
                #expect(!row.accepts(bad))
                #expect(!Self.diagnostics(bad, at: row.path).isEmpty, "\(row.id) = \(bad)")
            }
        }
    }

    @Test func opacityRowsAreFractionsThatFollowTheWindowOpacity() throws {
        for surface in Self.surfaces {
            let row = try #require(SettingsSchema.descriptor(for: Self.path(surface, "opacity")))
            guard case .number(let number) = row.kind else {
                Issue.record("\(row.id) is not a number")
                continue
            }
            #expect(number.range == 0...1 && number.step == 0.05 && number.unit == .fraction)
            #expect(row.textKeys.defaultLabel == "settings.default.windowOpacity")
            #expect(row.defaultLabel == "Window opacity")
            for good in [0, 0.5, 1] as [JSONValue] {
                #expect(row.accepts(good))
                #expect(Self.diagnostics(good, at: row.path).isEmpty, "\(row.id) = \(good)")
            }
            for bad in [-1, 2, "1"] as [JSONValue] {
                #expect(!row.accepts(bad))
                #expect(!Self.diagnostics(bad, at: row.path).isEmpty, "\(row.id) = \(bad)")
            }
        }
    }

    @Test func unknownSurfacesAndFieldsAreReported() {
        let root: JSONValue = ["appearance": ["surfaces": ["titlebar": ["color": "#000000"], "sidebar": ["tint": "#000000"]]]]
        let paths = Set(CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: []).diagnostics.map(\.path))
        #expect(paths.contains("appearance.surfaces.titlebar"))
        #expect(paths.contains("appearance.surfaces.sidebar.tint"))
    }
}
