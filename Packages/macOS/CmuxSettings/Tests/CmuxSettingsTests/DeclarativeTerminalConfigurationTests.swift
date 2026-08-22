import CmuxSettings
import Foundation
import Testing

@Suite("Declarative terminal configuration")
struct DeclarativeTerminalConfigurationTests {
    @Test("reads nested JSONC values from the same config surface")
    func readsNestedValues() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-declarative-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("cmux.json")
        try Data(
            """
            {
              // Keep this comment: snapshot reads JSONC.
              "terminal": {
                "newSurfaceWorkingDirectory": {
                  "policy": "fixedPath",
                  "path": "~/src"
                },
                "shellStartup": {
                  "mode": "nonLogin",
                  "command": "mise activate zsh"
                }
              }
            }
            """.utf8
        ).write(to: file)

        let snapshot = DeclarativeTerminalConfiguration().snapshot(fileURL: file)
        #expect(snapshot.workingDirectoryPolicy == .fixedPath)
        #expect(snapshot.workingDirectoryPath == "~/src")
        #expect(snapshot.shellStartupMode == .nonLogin)
        #expect(snapshot.shellStartupCommand == "mise activate zsh")
    }

    @Test("invalid policy fails closed as absent")
    func invalidPolicyIsAbsent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-declarative-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("cmux.json")
        try Data(#"{"terminal":{"newSurfaceWorkingDirectory":{"policy":"surprise"}}}"#.utf8)
            .write(to: file)

        let snapshot = DeclarativeTerminalConfiguration().snapshot(fileURL: file)
        #expect(snapshot.workingDirectoryPolicy == nil)
        #expect(snapshot.effectiveWorkingDirectoryPolicy(legacyInheritanceEnabled: true) == .inheritActivePane)
        #expect(snapshot.effectiveWorkingDirectoryPolicy(legacyInheritanceEnabled: false) == .workspaceRoot)
        #expect(snapshot.shellStartupMode == .login)
    }

    @Test("invalid shell mode falls back to the safe login default")
    func invalidShellModeFallsBackToLogin() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-declarative-shell-mode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("cmux.json")
        try Data(
            #"{"terminal":{"shellStartup":{"mode":"not-a-shell-mode","command":"  "}}}"#.utf8
        ).write(to: file)

        let snapshot = DeclarativeTerminalConfiguration().snapshot(fileURL: file)
        #expect(snapshot.shellStartupMode == .login)
        #expect(snapshot.shellStartupCommand.isEmpty)
    }

    @Test("missing file uses safe defaults")
    func missingFileUsesDefaults() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-missing-\(UUID().uuidString).json")
        let snapshot = DeclarativeTerminalConfiguration().snapshot(fileURL: file)
        #expect(snapshot.workingDirectoryPolicy == nil)
        #expect(snapshot.effectiveWorkingDirectoryPolicy(legacyInheritanceEnabled: true) == .inheritActivePane)
        #expect(snapshot.effectiveWorkingDirectoryPolicy(legacyInheritanceEnabled: false) == .workspaceRoot)
        #expect(snapshot.workingDirectoryPath.isEmpty)
        #expect(snapshot.shellStartupMode == .login)
        #expect(snapshot.shellStartupCommand.isEmpty)
    }

    @Test("typed settings writes converge on the same nested cmux.json file")
    func typedWritesUseTheSharedFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-declarative-write-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("cmux.json")
        let catalog = SettingCatalog()
        let store = JSONConfigStore(fileURL: file)

        try await store.set(.fixedPath, for: catalog.terminal.newSurfaceWorkingDirectoryPolicy)
        try await store.set("~/src", for: catalog.terminal.newSurfaceWorkingDirectoryPath)
        try await store.set(.nonLogin, for: catalog.terminal.shellStartupMode)
        try await store.set("mise activate zsh", for: catalog.terminal.shellStartupCommand)

        let snapshot = DeclarativeTerminalConfiguration().snapshot(fileURL: file)
        #expect(snapshot.workingDirectoryPolicy == .fixedPath)
        #expect(snapshot.workingDirectoryPath == "~/src")
        #expect(snapshot.shellStartupMode == .nonLogin)
        #expect(snapshot.shellStartupCommand == "mise activate zsh")
    }

    @Test("published snapshots update after an authoritative config edit")
    @MainActor
    func publishedSnapshotUpdatesAfterEdit() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-declarative-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("cmux.json")
        try Data(
            #"{"terminal":{"shellStartup":{"mode":"login","command":""}}}"#.utf8
        ).write(to: file, options: [.atomic])

        let configuration = DeclarativeTerminalConfiguration()
        let cache = DeclarativeTerminalConfigurationCache(
            initialSnapshot: configuration.snapshot(fileURL: file),
            fileURL: file
        )
        #expect(cache.snapshot(fileURL: file).shellStartupMode == .login)

        try Data(
            #"{"terminal":{"shellStartup":{"mode":"nonLogin","command":"echo startup"}}}"#.utf8
        ).write(to: file, options: [.atomic])

        // The cache never performs a synchronous filesystem read on a spawn
        // path; the observer publishes the newly parsed value explicitly.
        #expect(cache.snapshot(fileURL: file).shellStartupMode == .login)
        cache.replace(configuration.snapshot(fileURL: file), fileURL: file)
        let refreshed = cache.snapshot(fileURL: file)
        #expect(refreshed.shellStartupMode == .nonLogin)
        #expect(refreshed.shellStartupCommand == "echo startup")
    }
}
