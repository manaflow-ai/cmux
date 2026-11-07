import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// `SettingsController.chainUserWillWrite`: owners of per-Mac records (hang reports, usage
/// recording) add their hooks without replacing each other's; every hook sees each write by the
/// person, and a failed write runs every undo, the newest first.
@MainActor @Suite(.serialized) struct UserWillWriteChainTests {
    final class Log {
        var lines: [String] = []
    }

    private func settings(home: URL) async throws -> SettingsController {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let url = home.appending(path: "cmux-next.json")
        try Data("{}".utf8).write(to: url)
        let settings = SettingsController(registry: .standard(), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()),
                                          managedWatchFiles: [])
        await settings.reload()
        return settings
    }

    private func chain(_ settings: SettingsController, _ log: Log, names: [String], undoing: Set<String>) {
        for name in names {
            settings.chainUserWillWrite { descriptor, _ in
                log.lines.append("\(name) \(descriptor.id)")
                guard undoing.contains(name) else { return nil }
                return { log.lines.append("undo \(name)") }
            }
        }
    }

    @Test func everyChainedHookSeesThePersonsWriteAndAnEarlierOneIsKept() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "cn-user-will-write-chain-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = try await settings(home: home)
        let log = Log()
        chain(settings, log, names: ["hang", "usage"], undoing: ["hang", "usage"])
        try await settings.setSetting(at: UsageRecordingSetting.path, to: .bool(true), by: .user)
        #expect(log.lines == ["hang diagnostics.usageRecording", "usage diagnostics.usageRecording"])
    }

    @Test func aFailedWriteRunsEveryUndoNewestFirst() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "cn-user-will-write-chain-\(UUID().uuidString)")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.path)
            try? FileManager.default.removeItem(at: home)
        }
        let settings = try await settings(home: home)
        let log = Log()
        chain(settings, log, names: ["a", "b", "c"], undoing: ["a", "c"])
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: home.appending(path: "cmux-next.json").path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: home.path)
        await #expect(throws: (any Error).self) {
            try await settings.setSetting(at: HangReportsSetting.path, to: .bool(true), by: .user)
        }
        #expect(log.lines == ["a diagnostics.hangReports", "b diagnostics.hangReports", "c diagnostics.hangReports", "undo c", "undo a"])
    }
}
