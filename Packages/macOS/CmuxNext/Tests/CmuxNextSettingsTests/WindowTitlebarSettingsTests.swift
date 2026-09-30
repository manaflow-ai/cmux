import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing

/// `window.titlebar`: "minimal" unless the file says "standard"; a bad value
/// keeps "minimal" and reports a diagnostic; removing the key restores it.
@Suite struct WindowTitlebarSettingsTests {
    func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func defaultsToMinimal() throws {
        #expect(try parse("{}").titlebar == .minimal)
        #expect(try parse("{}").diagnostics.isEmpty)
        #expect(CmuxConfigSnapshot.empty.titlebar == .minimal)
    }

    @Test func readsEveryStyle() throws {
        for style in TitlebarStyle.allCases {
            #expect(try parse(#"{"window": {"titlebar": "\#(style.rawValue)"}}"#).titlebar == style)
        }
    }

    @Test func badValuesKeepMinimalWithADiagnostic() throws {
        for text in [#"{"window": {"titlebar": "hidden"}}"#, #"{"window": {"titlebar": true}}"#] {
            let snapshot = try parse(text)
            #expect(snapshot.titlebar == .minimal, "\(text)")
            #expect(snapshot.diagnostics.map(\.path) == ["window.titlebar"], "\(text)")
        }
    }

    @MainActor @Test func appliesToDesignSettingsAndRevertsWhenRemoved() throws {
        let design = DesignSettings()
        let applier = SettingsApplier(design: design, registry: ActionRegistry.standard())
        applier.apply(try parse(#"{"window": {"titlebar": "standard"}}"#))
        #expect(design.titlebar == .standard)
        applier.apply(try parse("{}"))
        #expect(design.titlebar == .minimal)
    }

    @MainActor @Test func doubleClickFollowsTheUsersMacOSSetting() throws {
        let name = "cmux-next-titlebar-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let cases: [(String?, WindowTitlebar.DoubleClickAction)] = [
            (nil, .zoom), ("Maximize", .zoom), ("Fill", .zoom), ("Minimize", .minimize), ("None", .none),
        ]
        for (value, action) in cases {
            defaults.set(value, forKey: "AppleActionOnDoubleClick")
            #expect(WindowTitlebar.doubleClickAction(defaults: defaults) == action, "\(value ?? "unset")")
        }
        defaults.removeObject(forKey: "AppleActionOnDoubleClick")
        defaults.set(true, forKey: "AppleMiniaturizeOnDoubleClick")
        #expect(WindowTitlebar.doubleClickAction(defaults: defaults) == .minimize)
    }
}
