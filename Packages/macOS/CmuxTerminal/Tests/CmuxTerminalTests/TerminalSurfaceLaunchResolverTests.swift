import CmuxTerminalCore
import Foundation
import Testing
@testable import CmuxTerminal

@MainActor
struct TerminalSurfaceLaunchResolverTests {
    @Test func customCommandAndEmbeddedLaunchShareOneResolvedEnvironment() {
        let workspaceID = UUID()
        let surfaceID = UUID()
        var template = CmuxSurfaceConfigTemplate()
        template.workingDirectory = "/template"
        template.command = "echo template"
        template.environmentVariables = [
            "TERM": "bad-term",
            "BASE": "base",
            "PATH": "/usr/bin",
        ]
        template.initialInput = "template-input"
        let resolver = makeResolver(defaultArguments: ["/bin/test-shell", "-l"])

        let resolved = resolver.resolve(
            TerminalSurfaceLaunchRequest(
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                configTemplate: template,
                workingDirectory: "/request",
                portOrdinal: 3,
                initialCommand: "printf '%s' '$HOME'",
                initialInput: "request-input",
                runtimeInitialInput: "runtime-input",
                initialEnvironmentOverrides: [
                    "TERM": "still-bad",
                    "OVERRIDE": "override",
                ],
                additionalEnvironment: [
                    "BASE": "additional",
                    "ADDED": "added",
                ]
            ),
            commandShim: nil
        )

        #expect(resolved.workingDirectory == "/request")
        #expect(resolved.command == "printf '%s' '$HOME'")
        #expect(resolved.arguments == nil)
        #expect(resolved.initialInput == "runtime-input")
        #expect(resolved.environment["TERM"] == "xterm-256color")
        #expect(resolved.environment["BASE"] == "additional")
        #expect(resolved.environment["OVERRIDE"] == "override")
        #expect(resolved.environment["ADDED"] == "added")
        #expect(resolved.environment["CMUX_WORKSPACE_ID"] == workspaceID.uuidString)
        #expect(resolved.environment["CMUX_SURFACE_ID"] == surfaceID.uuidString)
        #expect(resolved.environment["CMUX_SOCKET_PATH"] == "/tmp/cmux-test.sock")
        #expect(resolved.environment["CMUX_PORT"] == "40300")
        #expect(resolved.environment["CMUX_PORT_END"] == "40399")
        #expect(resolved.environment["CMUX_PORT_RANGE"] == "100")
    }

    @Test func defaultShellUsesExplicitLoginArgumentsAndNoCommand() {
        let resolver = makeResolver(defaultArguments: ["/usr/bin/login", "-flp", "tester"])
        let resolved = resolver.resolve(
            TerminalSurfaceLaunchRequest(
                workspaceID: UUID(),
                surfaceID: UUID(),
                configTemplate: nil,
                workingDirectory: nil,
                portOrdinal: 0,
                initialCommand: nil,
                initialInput: nil,
                initialEnvironmentOverrides: [:],
                additionalEnvironment: [:]
            ),
            commandShim: nil
        )

        #expect(resolved.command == nil)
        #expect(resolved.arguments == ["/usr/bin/login", "-flp", "tester"])
    }

    private func makeResolver(defaultArguments: [String]) -> TerminalSurfaceLaunchResolver {
        TerminalSurfaceLaunchResolver(
            userGhosttyShellIntegrationMode: { "none" },
            spawnPolicyProvider: FakeSpawnPolicyProvider(),
            runtimeFilesystem: TerminalSurfaceRuntimeFilesystem(
                claudeCommandShimTemporaryDirectory: URL(fileURLWithPath: "/tmp"),
                installClaudeCommandShim: { _, _, _ in nil },
                isExecutableFile: { _ in false }
            ),
            sessionPortBase: 40_000,
            sessionPortRangeSize: 100,
            resourceURL: nil,
            bundleIdentifier: "com.cmux.test",
            ambientEnvironment: ["PATH": "/usr/bin", "SHELL": "/bin/zsh"],
            defaultShellArguments: { defaultArguments }
        )
    }
}
