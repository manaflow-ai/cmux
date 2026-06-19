import Foundation
import Testing
import CmuxTerminalCore

@Suite struct CmuxOwnedTmuxSessionTests {
    @Test func sessionNameIsHumanReadableAndTmuxSafe() {
        let workspaceId = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let panelId = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!

        let name = CmuxOwnedTmuxSession.sessionName(
            workspaceTitle: "Example Workspace / Project Alpha ✨",
            workspaceDirectory: "/tmp/project-alpha",
            workspaceId: workspaceId,
            panelId: panelId
        )

        #expect(name == "cmux-project-alpha-example-workspace-project-alpha-aaaaaaaa")
        #expect(!name.contains(":"))
        #expect(!name.contains(" "))
        #expect(name.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "-" || character == "_" || character == ".")
        })
    }

    @Test func launcherScriptCarriesOwnershipMetadataAndEnvironmentFilter() {
        let workspaceId = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let panelId = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!

        let script = CmuxOwnedTmuxSession.launcherScript(
            sessionName: "cmux-project-alpha-claude-aaaaaaaa",
            workspaceId: workspaceId,
            panelId: panelId,
            workingDirectory: "/tmp/project-alpha",
            startupCommand: "claude --dangerously-skip-permissions"
        )

        #expect(script.contains(CmuxOwnedTmuxSession.ownedOption))
        #expect(script.contains(CmuxOwnedTmuxSession.workspaceOption))
        #expect(script.contains(CmuxOwnedTmuxSession.panelOption))
        #expect(script.contains("NODE_OPTIONS"))
        #expect(script.contains("claude --dangerously-skip-permissions"))
        #expect(script.contains("exec \"$_cmux_tmux\" attach-session -t \"$_cmux_session\""))
    }

    @Test func writeLauncherScriptCreatesExecutableZshScript() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-owned-tmux-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: directory) }

        let workspaceId = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let panelId = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let scriptURL = try CmuxOwnedTmuxSession.writeLauncherScript(
            sessionName: "cmux-project-alpha-terminal-aaaaaaaa",
            workspaceId: workspaceId,
            panelId: panelId,
            workingDirectory: "/tmp/project-alpha",
            startupCommand: nil,
            fileManager: fileManager,
            directory: directory,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let attributes = try fileManager.attributesOfItem(atPath: scriptURL.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue == 0o700)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-n", scriptURL.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
