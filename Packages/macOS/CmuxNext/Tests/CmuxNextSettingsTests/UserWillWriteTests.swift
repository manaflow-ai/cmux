import CmuxNextAppearance
@testable import CmuxNextSettings
import Foundation
import Testing

/// `SettingsController.userWillWrite`: called only for the person's writes, before the file
/// write, and its undo runs when that write fails, so state recorded for a write (the hang
/// reports consent record) never outlives a write that did not happen.
@MainActor @Suite(.serialized) struct UserWillWriteTests {
    final class Calls {
        var seen: [(path: [String], value: JSONValue?)] = []
        var undone = 0
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

    private func watch(_ settings: SettingsController) -> Calls {
        let calls = Calls()
        settings.userWillWrite = { descriptor, value in
            calls.seen.append((descriptor.path, value))
            return { calls.undone += 1 }
        }
        return calls
    }

    @Test func onlyThePersonsWritesCallTheHookAndASuccessfulWriteKeepsWhatItRecorded() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "cn-user-will-write-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = try await settings(home: home)
        let calls = watch(settings)
        try await settings.setSetting(at: HangReportsSetting.path, to: .bool(true), by: .user)
        // A caller other than the person (refused for this key) never reaches the hook.
        _ = try? await settings.setSetting(at: HangReportsSetting.path, to: .bool(true), by: .caller("cli"))
        try await settings.setSetting(at: HangReportsSetting.path, to: nil, by: .user)
        #expect(calls.seen.map(\.path) == [HangReportsSetting.path, HangReportsSetting.path])
        #expect(calls.seen.map(\.value) == [.bool(true), nil])
        #expect(calls.undone == 0)
    }

    @Test func aFailedWriteRunsTheUndo() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "cn-user-will-write-\(UUID().uuidString)")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.path)
            try? FileManager.default.removeItem(at: home)
        }
        let settings = try await settings(home: home)
        let calls = watch(settings)
        // A folder the write cannot replace the file in (no write permission): the write throws.
        let file = home.appending(path: "cmux-next.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: home.path)
        await #expect(throws: (any Error).self) {
            try await settings.setSetting(at: HangReportsSetting.path, to: .bool(true), by: .user)
        }
        #expect(calls.seen.count == 1)
        #expect(calls.undone == 1)
    }
}
