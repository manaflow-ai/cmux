@testable import CmuxNextSettings
import Testing

/// `app.confirmQuit`, the key classic cmux reads from the same cmux.json:
/// "always", "dirty-only" or "never". Unset, cmux NEXT does not ask (Lawrence
/// 2026-10-07); a classic `true`/`false` reads as "always"/"never".
struct ConfirmQuitSettingTests {
    private func snapshot(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map { .object(["app": .object(["confirmQuit": $0])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func absentNeverAsks() {
        let parsed = snapshot(nil)
        #expect(parsed.confirmQuit == .never)
        #expect(!parsed.diagnostics.contains { $0.path == "app.confirmQuit" })
    }

    @Test func classicValuesAreRead() {
        #expect(snapshot("always").confirmQuit == .always)
        #expect(snapshot("dirty-only").confirmQuit == .dirtyOnly)
        #expect(snapshot("never").confirmQuit == .never)
    }

    @Test func classicBooleansAreRead() {
        #expect(snapshot(true).confirmQuit == .always)
        #expect(snapshot(false).confirmQuit == .never)
    }

    @Test func aBadValueNeverAsksWithADiagnostic() {
        let parsed = snapshot("sometimes")
        #expect(parsed.confirmQuit == .never)
        #expect(parsed.diagnostics.contains { $0.path == "app.confirmQuit" })
    }

    @Test func theSettingsWindowShowsIt() {
        let descriptor = SettingsSchema.descriptor(for: ConfirmQuitMode.configPath)
        #expect(descriptor != nil)
        #expect(descriptor.map { $0.accepts(.string("dirty-only")) } == true)
        #expect(descriptor.map { $0.accepts(.string("sometimes")) } == false)
    }
}
