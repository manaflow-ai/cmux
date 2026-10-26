@testable import CmuxNextSettings
import Testing

/// `app.confirmQuit`, the key classic cmux reads from the same cmux.json:
/// "always", "dirty-only" or "never". Unset, cmux NEXT asks, as classic does
/// (#25567). Like classic, it takes strings only.
struct ConfirmQuitSettingTests {
    private func snapshot(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map { .object(["app": .object(["confirmQuit": $0])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func absentAlwaysAsks() {
        let parsed = snapshot(nil)
        #expect(parsed.confirmQuit == .always)
        #expect(!parsed.diagnostics.contains { $0.path == "app.confirmQuit" })
    }

    @Test func classicValuesAreRead() {
        #expect(snapshot("always").confirmQuit == .always)
        #expect(snapshot("dirty-only").confirmQuit == .dirtyOnly)
        #expect(snapshot("never").confirmQuit == .never)
    }

    /// Classic's boolean fallback is another key (`app.warnBeforeQuit`); a
    /// boolean here is refused, as the Settings window refuses it.
    @Test func aBooleanIsRefused() {
        let parsed = snapshot(true)
        #expect(parsed.confirmQuit == .always)
        #expect(parsed.diagnostics.contains { $0.path == "app.confirmQuit" })
        #expect(SettingsSchema.descriptor(for: ConfirmQuitMode.configPath).map { $0.accepts(true) } == false)
    }

    @Test func aBadValueAsksWithADiagnostic() {
        let parsed = snapshot("sometimes")
        #expect(parsed.confirmQuit == .always)
        #expect(parsed.diagnostics.contains { $0.path == "app.confirmQuit" })
    }

    @Test func theSettingsWindowShowsIt() {
        let descriptor = SettingsSchema.descriptor(for: ConfirmQuitMode.configPath)
        #expect(descriptor != nil)
        #expect(descriptor.map { $0.accepts(.string("dirty-only")) } == true)
        #expect(descriptor.map { $0.accepts(.string("sometimes")) } == false)
        #expect(descriptor?.defaultValue == .string("always"))
    }
}
