import AppKit
@testable import CmuxNextActions
@testable import CmuxNextSettings
import Testing

/// `appearance.mode` (Leo, 2026-11-21: "debate on the appearance; the functionality is relatively
/// obvious"): the palette and CLI actions `appearance.mode.light`, `.dark` and `.system` switch this
/// process's appearance (`NSApp.appearance`, never the Mac's) and save the choice to cmux.json, and a
/// cmux.json value parses to the mode the app applies. Match System stays the default.
@MainActor @Suite(.serialized) struct AppearanceModeTests {
    private static func isDark(_ app: NSApplication) -> Bool {
        app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    @Test func thePaletteActionsSwitchTheAppsAppearanceAndSaveIt() {
        let app = NSApplication.shared
        let before = app.appearance
        defer { app.appearance = before }
        let registry = ActionRegistry()
        // Seeded until the app FFI pin carries the rows (Rust: cmux-action-catalog appearance_mode.rs).
        registry.seed(AppearanceMode.allCases.map {
            ActionDescriptor(id: ActionID(rawValue: AppearanceModeSetting.actionID($0)), title: $0.rawValue, category: .settings)
        })
        var saved: [([String], JSONValue?)] = []
        AppearanceModeSetting.bindActions(into: registry, save: { saved.append(($0, $1)); return nil }, app: app)

        #expect(registry.perform("appearance.mode.dark"))
        #expect(app.appearance?.name == .darkAqua)
        #expect(Self.isDark(app))
        #expect(AppearanceModeSetting.current(of: app) == .dark)
        #expect(registry.perform("appearance.mode.light"))
        #expect(app.appearance?.name == .aqua)
        #expect(!Self.isDark(app))
        #expect(AppearanceModeSetting.current(of: app) == .light)
        #expect(registry.perform("appearance.mode.system"))
        #expect(app.appearance == nil, "Match System clears the override so macOS decides")
        #expect(AppearanceModeSetting.current(of: app) == .system)
        #expect(saved.map(\.0) == Array(repeating: ["appearance", "mode"], count: 3))
        #expect(saved.map(\.1) == [.string("dark"), .string("light"), nil], "the default removes the key")
    }

    @Test func cmuxJSONPicksTheModeAndSystemIsTheDefault() {
        let parse = { (value: JSONValue?) in
            CmuxConfigSnapshot.parse(value.map { .object(["appearance": .object(["mode": $0])]) } ?? .object([:]),
                                     validDensities: SettingsApplier.validDensities, validMetrics: SettingsApplier.validMetrics)
        }
        #expect(parse(nil).appearanceMode == .system)
        #expect(parse(.string("dark")).appearanceMode == .dark)
        #expect(parse(.string("light")).appearanceMode == .light)
        let bad = parse(.string("sepia"))
        #expect(bad.appearanceMode == .system)
        #expect(bad.diagnostics.contains { $0.path == "appearance.mode" })
        #expect(AppearanceModeSetting.fallback == .system)
    }

    @Test func applyingAModeWritesTheAppearanceOnlyOnAChange() {
        let app = NSApplication.shared
        let before = app.appearance
        defer { app.appearance = before }
        AppearanceModeSetting.apply(.dark, to: app)
        let pinned = app.appearance
        AppearanceModeSetting.apply(.dark, to: app)
        #expect(app.appearance === pinned)
        AppearanceModeSetting.apply(.system, to: app)
        #expect(app.appearance == nil)
    }
}
