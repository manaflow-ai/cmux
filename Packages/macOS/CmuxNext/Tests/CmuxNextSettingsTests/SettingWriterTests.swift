import CmuxNextActions
import CmuxNextDesign
import Foundation
import Testing
@testable import CmuxNextSettings

/// SECURITY (agent_settable): the one write path refuses a non-user writer for a key only the user
/// may change, lets every writer change agent-settable keys, refuses managed keys for everyone,
/// and lets only the user Reset All.
@MainActor @Suite(.serialized) struct SettingWriterTests {
    private func make(managed: ManagedPreferences = ManagedPreferences()) async throws -> (SettingsController, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "setting-writer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(managed), managedWatchFiles: [])
        await settings.reload()
        return (settings, directory)
    }

    @Test func aNonUserWriterCannotChangeAUserOnlyKey() async throws {
        let (settings, directory) = try await make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let userOnly = try #require(SettingsSchema.descriptor(for: ["history", "terminalCommands"]))
        #expect(SettingsSchema.agentSettable(userOnly) == false)
        for writer in [SettingWriter.caller("cli"), .caller("mcp"), .caller("script"), .caller("page"), SettingWriter(.remote)] {
            await #expect(throws: SettingUserOnly(key: userOnly.id, writer: writer)) {
                try await settings.setSetting(userOnly, to: .bool(false), by: writer)
            }
        }
        #expect(try await settings.file.value(at: userOnly.path) == nil, "nothing was written")
        try await settings.setSetting(userOnly, to: .bool(false), by: .user)
        #expect(try await settings.file.value(at: userOnly.path) == .bool(false))
    }

    @Test func anyWriterMayChangeAnAgentSettableKey() async throws {
        let (settings, directory) = try await make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let density = try #require(SettingsSchema.descriptor(for: ["appearance", "density"]))
        try await settings.setSetting(density, to: "compact", by: .caller("mcp"))
        #expect(try await settings.file.value(at: density.path) == "compact")
    }

    @Test func managedKeysStayRefusedForTheUserAndOnlyTheUserResetsAll() async throws {
        let (settings, directory) = try await make(managed: ManagedPreferences(forced: ["history.terminalCommands": false]))
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = try #require(SettingsSchema.descriptor(for: ["history", "terminalCommands"]))
        await #expect(throws: SettingManaged.self) { try await settings.setSetting(key, to: .bool(true), by: .user) }
        await #expect(throws: SettingUserOnly.self) { try await settings.resetAllSettings(by: .caller("cli")) }
        try await settings.resetAllSettings(by: .user)
    }

    @Test func anActionRunsOriginIsItsWriter() {
        #expect(SettingWriter.currentRun() == .user, "outside a run: a direct gesture in the app")
        ActionRunScope.$current.withValue(ActionRunScope(origin: .cli, allowsViewChange: false)) {
            #expect(SettingWriter.currentRun() == .caller("cli"))
        }
        ActionRunScope.$current.withValue(ActionRunScope(origin: .page, allowsViewChange: true)) {
            #expect(SettingWriter.currentRun() == .caller("page"))
        }
    }
}
