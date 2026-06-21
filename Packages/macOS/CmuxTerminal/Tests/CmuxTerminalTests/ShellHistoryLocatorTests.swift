import Foundation
import Testing
@testable import CmuxTerminal

/// Per-tab shell-history keying and the spawn-time `CMUX_SHELL_HISTFILE` env
/// injection. The key is the surface id alone (stable across restore), which is
/// what lets a tab recover its own history for ↑ recall on reopen.
@Suite("ShellHistoryLocator")
struct ShellHistoryLocatorTests {
    private let tempAppSupport = FileManager.default.temporaryDirectory
        .appendingPathComponent("cmux-shell-history-tests-\(UUID().uuidString)", isDirectory: true)

    @Test func sameSurfaceIsStable() {
        let id = UUID()
        let a = ShellHistoryLocator.historyFileURL(
            surfaceID: id, fileExtension: "zsh_history", appSupportDirectory: tempAppSupport
        )
        let b = ShellHistoryLocator.historyFileURL(
            surfaceID: id, fileExtension: "zsh_history", appSupportDirectory: tempAppSupport
        )
        #expect(a == b)
        #expect(a != nil)
    }

    @Test func differentSurfacesGetDifferentFiles() {
        let a = ShellHistoryLocator.historyFileURL(
            surfaceID: UUID(), fileExtension: "zsh_history", appSupportDirectory: tempAppSupport
        )
        let b = ShellHistoryLocator.historyFileURL(
            surfaceID: UUID(), fileExtension: "zsh_history", appSupportDirectory: tempAppSupport
        )
        #expect(a != b)
        // Same flat directory (keyed only by surface id, not by project).
        #expect(a?.deletingLastPathComponent() == b?.deletingLastPathComponent())
    }

    @Test func pathLayoutIsAppSupportShellHistorySurface() {
        let id = UUID()
        let url = ShellHistoryLocator.historyFileURL(
            surfaceID: id, fileExtension: "zsh_history", appSupportDirectory: tempAppSupport
        )
        #expect(url?.lastPathComponent == "\(id.uuidString).zsh_history")
        #expect(url?.path.contains("/cmux/shell-history/") == true)
    }

    @Test func commandsFileIsKeyedBySurfaceUnderCommandsBucket() {
        let id = UUID()
        let url = ShellHistoryLocator.commandsFileURL(surfaceID: id, appSupportDirectory: tempAppSupport)
        #expect(url?.lastPathComponent == "\(id.uuidString).commands.json")
        #expect(url?.deletingLastPathComponent().lastPathComponent == "_commands")
    }

    // MARK: - applyManagedShellHistoryEnvironment

    @Test func zshSpawnInjectsProtectedHistfile() {
        var env: [String: String] = [:]
        var protected: Set<String> = []
        let id = UUID()
        TerminalSurface.applyManagedShellHistoryEnvironment(
            shell: "/bin/zsh",
            surfaceID: id,
            to: &env,
            protectedKeys: &protected,
            appSupportDirectory: tempAppSupport
        )
        #expect(env["CMUX_SHELL_HISTFILE"]?.hasSuffix("\(id.uuidString).zsh_history") == true)
        #expect(protected.contains("CMUX_SHELL_HISTFILE"))
    }

    @Test func bashSpawnUsesBashHistoryExtension() {
        var env: [String: String] = [:]
        var protected: Set<String> = []
        TerminalSurface.applyManagedShellHistoryEnvironment(
            shell: "/bin/bash",
            surfaceID: UUID(),
            to: &env,
            protectedKeys: &protected,
            appSupportDirectory: tempAppSupport
        )
        #expect(env["CMUX_SHELL_HISTFILE"]?.hasSuffix(".bash_history") == true)
    }

    @Test func fishAndUnknownShellsAreSkipped() {
        for shell in ["/opt/homebrew/bin/fish", "/usr/local/bin/nu"] {
            var env: [String: String] = [:]
            var protected: Set<String> = []
            TerminalSurface.applyManagedShellHistoryEnvironment(
                shell: shell,
                surfaceID: UUID(),
                to: &env,
                protectedKeys: &protected,
                appSupportDirectory: tempAppSupport
            )
            #expect(env["CMUX_SHELL_HISTFILE"] == nil)
            #expect(!protected.contains("CMUX_SHELL_HISTFILE"))
        }
    }

    @Test func sameSurfaceResolvesToSameHistfileAcrossSpawns() {
        // The core invariant behind ↑ recall on reopen: a tab's surface id maps
        // to the same file on every spawn, independent of working directory.
        let id = UUID()
        func histfile() -> String? {
            var env: [String: String] = [:]
            var protected: Set<String> = []
            TerminalSurface.applyManagedShellHistoryEnvironment(
                shell: "/bin/zsh",
                surfaceID: id,
                to: &env,
                protectedKeys: &protected,
                appSupportDirectory: tempAppSupport
            )
            return env["CMUX_SHELL_HISTFILE"]
        }
        #expect(histfile() == histfile())
    }

    @Test func injectionCreatesParentDirectory() {
        var env: [String: String] = [:]
        var protected: Set<String> = []
        TerminalSurface.applyManagedShellHistoryEnvironment(
            shell: "/bin/zsh",
            surfaceID: UUID(),
            to: &env,
            protectedKeys: &protected,
            appSupportDirectory: tempAppSupport
        )
        let parent = (env["CMUX_SHELL_HISTFILE"]! as NSString).deletingLastPathComponent
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: parent, isDirectory: &isDir))
        #expect(isDir.boolValue)
    }
}
