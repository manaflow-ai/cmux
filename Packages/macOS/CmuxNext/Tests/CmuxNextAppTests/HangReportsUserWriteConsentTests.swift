@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextHangReports
import CmuxNextSettings
import Foundation
import Testing

/// The person's own write of `diagnostics.hangReports` records this Mac's consent (so Not Now on
/// the invitation, then the Settings switch in the same launch, sends), a failed write leaves no
/// record, and a write by anyone else or of another key records nothing.
@MainActor @Suite(.serialized) struct HangReportsUserWriteConsentTests {
    private func defaults() -> (UserDefaults, String) {
        let suite = "cn-hang-reports-consent-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    private func settings(home: URL, defaults: UserDefaults) async throws -> SettingsController {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let url = home.appending(path: "cmux-next.json")
        try Data("{}".utf8).write(to: url)
        let settings = SettingsController(registry: .standard(), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()),
                                          managedWatchFiles: [])
        await settings.reload()
        settings.userWillWrite = { descriptor, value in
            HangReportsController.recordUserWrite(defaults: defaults, path: descriptor.path, value: value)
        }
        return settings
    }

    private func consented(_ defaults: UserDefaults) -> Bool { defaults.object(forKey: HangReportsController.consentKey) is Date }

    @Test func theSettingsSwitchAfterNotNowSendsInTheSameLaunch() async throws {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let home = FileManager.default.temporaryDirectory.appending(path: suite)
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = try await settings(home: home, defaults: defaults)
        // Not Now on the invitation: asked, no record.
        defaults.set(true, forKey: HangReportsController.askedKey)
        #expect(HangReportsController.decision(defaults: defaults, settingOn: false) == .off)
        try await settings.setSetting(at: HangReportsSetting.path, to: .bool(true), by: .user)
        #expect(consented(defaults))
        #expect(HangReportsController.decision(defaults: defaults, settingOn: true) == .send)
        try await settings.setSetting(at: HangReportsSetting.path, to: .bool(false), by: .user)
        #expect(!consented(defaults))
    }

    @Test func aWriteByAnotherCallerOrOfAnotherKeyRecordsNothing() async throws {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let home = FileManager.default.temporaryDirectory.appending(path: suite)
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = try await settings(home: home, defaults: defaults)
        _ = try? await settings.setSetting(at: HangReportsSetting.path, to: .bool(true), by: .caller("cli"))
        try await settings.setSetting(at: ["terminal", "fontSize"], to: .number(15), by: .user)
        #expect(!consented(defaults))
    }

    @Test func aFailedWriteLeavesNoRecord() async throws {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let home = FileManager.default.temporaryDirectory.appending(path: suite)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.path)
            try? FileManager.default.removeItem(at: home)
        }
        let settings = try await settings(home: home, defaults: defaults)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: home.appending(path: "cmux-next.json").path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: home.path)
        await #expect(throws: (any Error).self) {
            try await settings.setSetting(at: HangReportsSetting.path, to: .bool(true), by: .user)
        }
        #expect(!consented(defaults))
        #expect(HangReportsController.decision(defaults: defaults, settingOn: false) != .send)
    }
}
