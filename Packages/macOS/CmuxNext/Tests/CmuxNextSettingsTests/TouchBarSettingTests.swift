import CmuxNextSettings
import Testing

/// `app.touchBar`: enabled by default, with a Settings toggle for people who prefer
/// the system Control Strip.
struct TouchBarSettingTests {
    private static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let app: [String: JSONValue] = value.map { ["touchBar": $0] } ?? [:]
        return CmuxConfigSnapshot.parse(.object(["app": .object(app)]), validDensities: [], validMetrics: [])
    }

    @Test func enabledByDefault() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.touchBar)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func canBeDisabledOrEnabled() {
        #expect(Self.parse(.bool(false)).touchBar == false)
        #expect(Self.parse(.bool(true)).touchBar)
    }

    @Test func invalidValueKeepsDefaultAndDiagnoses() {
        let snapshot = Self.parse(.string("yes"))
        #expect(snapshot.touchBar)
        #expect(snapshot.diagnostics.contains { $0.path == "app.touchBar" })
    }

    @Test func settingsListsTheToggle() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: CmuxConfigSnapshot.touchBarPath))
        #expect(descriptor.defaultValue == .bool(true))
        #expect(descriptor.section == .general)
    }
}
