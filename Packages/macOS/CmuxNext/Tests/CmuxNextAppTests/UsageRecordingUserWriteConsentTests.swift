@testable import CmuxNextApp
import CmuxNextControl
import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing

/// Hang reports and usage recording each keep this Mac's consent from the person's own writes,
/// through one chained `SettingsController.userWillWrite`: each records only its own key, the
/// order they start in does not matter, and a failed write leaves neither record.
@MainActor @Suite(.serialized) struct UsageRecordingUserWriteConsentTests {
    private func defaults() -> (UserDefaults, String) {
        let suite = "cn-usage-consent-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite) ?? .standard, suite)
    }

    private func settings(home: URL, defaults: UserDefaults, usageFirst: Bool) async throws -> SettingsController {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let url = home.appending(path: "cmux-next.json")
        try Data("{}".utf8).write(to: url)
        let settings = SettingsController(registry: .standard(), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()),
                                          managedWatchFiles: [])
        await settings.reload()
        let hang: @MainActor (SettingDescriptor, JSONValue?) -> (@MainActor () -> Void)? = { descriptor, value in
            HangReportsController.recordUserWrite(defaults: defaults, path: descriptor.path, value: value)
        }
        let usage: @MainActor (SettingDescriptor, JSONValue?) -> (@MainActor () -> Void)? = { descriptor, value in
            UsageRecorder.recordUserWrite(defaults: defaults, path: descriptor.path, value: value)
        }
        for hook in usageFirst ? [usage, hang] : [hang, usage] { settings.chainUserWillWrite(hook) }
        return settings
    }

    private func hangConsented(_ defaults: UserDefaults) -> Bool { defaults.object(forKey: HangReportsController.consentKey) is Date }

    @Test(arguments: [false, true])
    func eachSwitchRecordsOnlyItsOwnConsentInEitherStartOrder(usageFirst: Bool) async throws {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let home = FileManager.default.temporaryDirectory.appending(path: suite)
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = try await settings(home: home, defaults: defaults, usageFirst: usageFirst)
        try await settings.setSetting(at: HangReportsSetting.path, to: .bool(true), by: .user)
        #expect(hangConsented(defaults))
        #expect(!UsageRecorder.consented(defaults))
        try await settings.setSetting(at: UsageRecordingSetting.path, to: .bool(true), by: .user)
        #expect(UsageRecorder.consented(defaults))
        #expect(UsageRecorder.decision(settingOn: true, consented: UsageRecorder.consented(defaults), managedOff: false) == .record)
        try await settings.setSetting(at: UsageRecordingSetting.path, to: .bool(false), by: .user)
        #expect(!UsageRecorder.consented(defaults))
        #expect(hangConsented(defaults))
        try await settings.setSetting(at: HangReportsSetting.path, to: .bool(false), by: .user)
        #expect(!hangConsented(defaults))
    }

    /// Sharing keeps its own record beside recording's: the person's write of one never records
    /// the other, and turning sharing off removes only its own.
    @Test func sharingRecordsOnlyItsOwnConsent() async throws {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let home = FileManager.default.temporaryDirectory.appending(path: suite)
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = try await settings(home: home, defaults: defaults, usageFirst: true)
        settings.chainUserWillWrite { descriptor, value in
            UsageSharing.recordUserWrite(defaults: defaults, path: descriptor.path, value: value)
        }
        try await settings.setSetting(at: UsageRecordingSetting.path, to: .bool(true), by: .user)
        #expect(UsageRecorder.consented(defaults))
        #expect(!UsageSharing.consented(defaults))
        try await settings.setSetting(at: UsageSharingSetting.path, to: .bool(true), by: .user)
        #expect(UsageSharing.consented(defaults))
        try await settings.setSetting(at: UsageSharingSetting.path, to: .bool(false), by: .user)
        #expect(!UsageSharing.consented(defaults))
        #expect(UsageRecorder.consented(defaults))
    }

    @Test func aWriteByAnotherCallerRecordsNoConsent() async throws {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let home = FileManager.default.temporaryDirectory.appending(path: suite)
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = try await settings(home: home, defaults: defaults, usageFirst: false)
        _ = try? await settings.setSetting(at: UsageRecordingSetting.path, to: .bool(true), by: .caller("cli"))
        #expect(!UsageRecorder.consented(defaults))
        #expect(UsageRecorder.decision(settingOn: true, consented: UsageRecorder.consented(defaults), managedOff: false) == .confirm)
    }

    @Test func aFailedWriteLeavesNeitherRecord() async throws {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let home = FileManager.default.temporaryDirectory.appending(path: suite)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.path)
            try? FileManager.default.removeItem(at: home)
        }
        let settings = try await settings(home: home, defaults: defaults, usageFirst: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: home.appending(path: "cmux-next.json").path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: home.path)
        await #expect(throws: (any Error).self) {
            try await settings.setSetting(at: UsageRecordingSetting.path, to: .bool(true), by: .user)
        }
        await #expect(throws: (any Error).self) {
            try await settings.setSetting(at: HangReportsSetting.path, to: .bool(true), by: .user)
        }
        #expect(!UsageRecorder.consented(defaults))
        #expect(!hangConsented(defaults))
    }
}
