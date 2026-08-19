import CmuxSettings
import CmuxWorkspaces
import Foundation
import Testing

@Suite struct WorkspaceCreationWorkingDirectoryPolicyTests {
    @Test func explicitDirectoryWins() {
        #expect(
            resolve(explicit: "/explicit", inherited: "/inherited", enabled: true)
                == "/explicit"
        )
    }

    @Test func enabledInheritanceUsesSourceDirectory() {
        #expect(
            resolve(explicit: nil, inherited: "/inherited", enabled: true)
                == "/inherited"
        )
    }

    @Test func disabledInheritanceUsesConcreteDefault() {
        #expect(resolve(explicit: nil, inherited: "/inherited", enabled: false) == "/default")
    }

    @Test func missingInheritedDirectoryUsesConcreteDefault() {
        #expect(resolve(explicit: nil, inherited: nil, enabled: true) == "/default")
    }

    @Test func workspaceRootIgnoresActivePaneDirectory() {
        let policy = WorkspaceCreationWorkingDirectoryPolicy(policy: .workspaceRoot)
        #expect(
            policy.resolve(
                explicitWorkingDirectory: nil,
                inheritedWorkingDirectory: "/active",
                defaultWorkingDirectory: "/default",
                workspaceRootWorkingDirectory: "/root"
            ) == "/root"
        )
    }

    @Test func explicitDirectoryAlwaysWinsOverConfiguredPolicy() {
        let policy = WorkspaceCreationWorkingDirectoryPolicy(
            policy: .fixedPath,
            fixedPath: "/tmp"
        )
        #expect(
            policy.resolve(
                explicitWorkingDirectory: "/explicit",
                inheritedWorkingDirectory: "/active",
                defaultWorkingDirectory: "/default",
                workspaceRootWorkingDirectory: "/root"
            ) == "/explicit"
        )
    }

    @Test func inheritActivePaneFallsBackToImmutableRoot() {
        let policy = WorkspaceCreationWorkingDirectoryPolicy(policy: .inheritActivePane)
        #expect(
            policy.resolve(
                explicitWorkingDirectory: nil,
                inheritedWorkingDirectory: "  ",
                defaultWorkingDirectory: "/default",
                workspaceRootWorkingDirectory: "/root"
            ) == "/root"
        )
    }

    @Test func fixedPathUsesAnExistingDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-policy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let policy = WorkspaceCreationWorkingDirectoryPolicy(
            policy: .fixedPath,
            fixedPath: directory.path
        )
        #expect(
            policy.resolve(
                explicitWorkingDirectory: nil,
                inheritedWorkingDirectory: "/active",
                defaultWorkingDirectory: "/default",
                workspaceRootWorkingDirectory: "/root"
            ) == directory.standardizedFileURL.path
        )
    }

    @Test func invalidFixedPathFailsClosedToWorkspaceRoot() {
        let policy = WorkspaceCreationWorkingDirectoryPolicy(
            policy: .fixedPath,
            fixedPath: "/definitely/not/a/real/cmux-directory"
        )
        #expect(
            policy.resolve(
                explicitWorkingDirectory: nil,
                inheritedWorkingDirectory: "/active",
                defaultWorkingDirectory: "/default",
                workspaceRootWorkingDirectory: "/root"
            ) == "/root"
        )
    }

    @Test func regularFileFixedPathFailsClosedToWorkspaceRoot() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-policy-file-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let policy = WorkspaceCreationWorkingDirectoryPolicy(
            policy: .fixedPath,
            fixedPath: file.path
        )
        #expect(
            policy.resolve(
                explicitWorkingDirectory: nil,
                inheritedWorkingDirectory: "/active",
                defaultWorkingDirectory: "/default",
                workspaceRootWorkingDirectory: "/root"
            ) == "/root"
        )
    }

    @Test func relativeFixedPathFailsClosedToWorkspaceRoot() {
        let policy = WorkspaceCreationWorkingDirectoryPolicy(
            policy: .fixedPath,
            fixedPath: "."
        )
        #expect(
            policy.resolve(
                explicitWorkingDirectory: nil,
                inheritedWorkingDirectory: "/active",
                defaultWorkingDirectory: "/default",
                workspaceRootWorkingDirectory: "/root"
            ) == "/root"
        )
    }

    @Test func tildeFixedPathExpandsAgainstTheUserHome() {
        let policy = WorkspaceCreationWorkingDirectoryPolicy(
            policy: .fixedPath,
            fixedPath: "~"
        )
        #expect(
            policy.resolve(
                explicitWorkingDirectory: nil,
                inheritedWorkingDirectory: "/active",
                defaultWorkingDirectory: "/default",
                workspaceRootWorkingDirectory: "/root"
            ) == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        )
    }

    private func resolve(explicit: String?, inherited: String?, enabled: Bool) -> String {
        WorkspaceCreationWorkingDirectoryPolicy(inheritanceEnabled: enabled).resolve(
            explicitWorkingDirectory: explicit,
            inheritedWorkingDirectory: inherited,
            defaultWorkingDirectory: "/default"
        )
    }
}
