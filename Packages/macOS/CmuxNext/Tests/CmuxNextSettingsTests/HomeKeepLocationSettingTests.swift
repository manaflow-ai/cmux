import CmuxNextSettings
import Foundation
import Testing

/// `home.attachments.keepLocation`: Settings > Home, off by default (the
/// composer strips photo GPS and a video's location before it attaches).
@MainActor @Suite struct HomeKeepLocationSettingTests {
    private func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: ["compact"], validMetrics: [])
    }

    @Test func parsesOffByDefaultWithADiagnosticForANonBool() throws {
        #expect(try parse("{}").homeKeepLocation == false)
        #expect(try parse(#"{"home": {"attachments": {"keepLocation": true}}}"#).homeKeepLocation == true)
        #expect(try parse(#"{"home": {"attachments": {"keepLocation": false}}}"#).homeKeepLocation == false)
        let bad = try parse(#"{"home": {"attachments": {"keepLocation": "yes"}}}"#)
        #expect(bad.homeKeepLocation == false)
        #expect(bad.diagnostics.map(\.path) == ["home.attachments.keepLocation"])
    }

    @Test func isAToggleInTheHomeSection() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: ["home", "attachments", "keepLocation"]))
        #expect(descriptor.section == .home)
        guard case .toggle = descriptor.kind else {
            Issue.record("expected a toggle")
            return
        }
        #expect(descriptor.defaultValue == .bool(false))
        #expect(SettingsSchema.settings(in: .home).map(\.id) == ["home.attachments.keepLocation"])
        #expect(SettingsSection.home.title == "Home")
    }
}
