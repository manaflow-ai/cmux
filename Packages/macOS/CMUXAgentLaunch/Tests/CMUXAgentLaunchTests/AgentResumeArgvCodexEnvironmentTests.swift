import CMUXAgentLaunch
import Foundation
import Testing

@Suite("AgentResumeArgv Codex environment rendering")
struct AgentResumeArgvCodexEnvironmentTests {
    @Test("Rendered Codex resume preserves env flags before routing through the wrapper")
    func renderedCodexResumeWithEnvironmentFlags() {
        let quote: (String) -> String = { "'" + $0 + "'" }
        let rendered = AgentResumeArgv.renderedPortableCodexResumeShellCommand(
            parts: ["env", "-iv", "-u", "HOME", "codex", "resume", "SID"],
            quote: quote
        )
        let substituted = [
            "'env'",
            "'-iv'",
            "'-u'",
            "'HOME'",
            "PATH=\"${PATH:-}\"",
            "CMUX_BUNDLED_CLI_PATH=\"${CMUX_BUNDLED_CLI_PATH:-}\"",
            "CMUX_CODEX_HOOKS_DISABLED=\"${CMUX_CODEX_HOOKS_DISABLED:-}\"",
            "CMUX_CODEX_WRAPPER_SHIM=\"${CMUX_CODEX_WRAPPER_SHIM:-}\"",
            "CMUX_CODEX_WRAPPER_SHIM_ROOT=\"${CMUX_CODEX_WRAPPER_SHIM_ROOT:-}\"",
            "CMUX_SOCKET_PATH=\"${CMUX_SOCKET_PATH:-}\"",
            "CMUX_SURFACE_ID=\"${CMUX_SURFACE_ID:-}\"",
            "CMUX_WORKSPACE_ID=\"${CMUX_WORKSPACE_ID:-}\"",
            AgentResumeArgv.codexWrapperShellExecutableToken,
            "'resume'",
            "'SID'",
        ].joined(separator: " ")

        #expect(
            rendered == AgentResumeArgv.portableCodexResumeShellCommand(posixCommand: substituted)
        )
    }

    @Test("Rendered custom Codex fork preserves env options and executable identity")
    func renderedCustomCodexForkWithEnvironmentOptions() {
        let quote: (String) -> String = { "'" + $0 + "'" }
        let rendered = AgentResumeArgv.renderedPortableCodexResumeShellCommand(
            parts: ["/usr/bin/env", "--chdir", "/tmp/work", "/opt/custom/codex", "fork", "SID"],
            quote: quote
        )
        let substituted = [
            "'/usr/bin/env'",
            "'--chdir'",
            "'/tmp/work'",
            "'CMUX_CUSTOM_CODEX_PATH=/opt/custom/codex'",
            AgentResumeArgv.codexWrapperShellExecutableToken,
            "'fork'",
            "'SID'",
        ].joined(separator: " ")

        #expect(
            rendered == AgentResumeArgv.portableCodexResumeShellCommand(posixCommand: substituted)
        )
    }

    @Test("Rendered custom Codex preserves clustered env utility-path options")
    func renderedCustomCodexWithClusteredEnvironmentUtilityPath() {
        let quote: (String) -> String = { "'" + $0 + "'" }
        let rendered = AgentResumeArgv.renderedPortableCodexResumeShellCommand(
            parts: ["env", "-iP/opt/codex/bin", "/opt/custom/codex", "resume", "SID"],
            quote: quote
        )

        #expect(rendered.hasPrefix("/bin/sh -c "))
        #expect(rendered.contains("'-iP/opt/codex/bin'"), "\(rendered)")
        #expect(rendered.contains("CMUX_CUSTOM_CODEX_PATH=/opt/custom/codex"), "\(rendered)")
        #expect(rendered.contains("CMUX_CODEX_WRAPPER_SHIM"), "\(rendered)")
    }

    @Test("Bare Codex with env utility path stays unchanged")
    func bareCodexWithEnvironmentUtilityPathIsNotRetargeted() {
        let quote: (String) -> String = { "'" + $0 + "'" }
        #expect(
            AgentResumeArgv.renderedPortableCodexResumeShellCommand(
                parts: ["env", "-P", "/opt/codex/bin", "codex", "resume", "SID"],
                quote: quote
            ) == "'env' '-P' '/opt/codex/bin' 'codex' 'resume' 'SID'"
        )
    }

    @Test("Rendered Codex resume keeps assignments outside env options")
    func renderedCodexResumeWithLeadingAssignmentAndEnvironmentOptions() {
        let quote: (String) -> String = { "'" + $0 + "'" }
        let rendered = AgentResumeArgv.renderedPortableCodexResumeShellCommand(
            parts: ["OUTER=value", "env", "-i", "codex", "resume", "SID"],
            quote: quote
        )
        let substituted = [
            "'env'",
            "'OUTER=value'",
            "'env'",
            "'-i'",
            "PATH=\"${PATH:-}\"",
            "CMUX_BUNDLED_CLI_PATH=\"${CMUX_BUNDLED_CLI_PATH:-}\"",
            "CMUX_CODEX_HOOKS_DISABLED=\"${CMUX_CODEX_HOOKS_DISABLED:-}\"",
            "CMUX_CODEX_WRAPPER_SHIM=\"${CMUX_CODEX_WRAPPER_SHIM:-}\"",
            "CMUX_CODEX_WRAPPER_SHIM_ROOT=\"${CMUX_CODEX_WRAPPER_SHIM_ROOT:-}\"",
            "CMUX_SOCKET_PATH=\"${CMUX_SOCKET_PATH:-}\"",
            "CMUX_SURFACE_ID=\"${CMUX_SURFACE_ID:-}\"",
            "CMUX_WORKSPACE_ID=\"${CMUX_WORKSPACE_ID:-}\"",
            AgentResumeArgv.codexWrapperShellExecutableToken,
            "'resume'",
            "'SID'",
        ].joined(separator: " ")

        #expect(
            rendered == AgentResumeArgv.portableCodexResumeShellCommand(posixCommand: substituted)
        )
    }

    @Test("Rendered clean environment preserves explicit cmux assignments")
    func renderedCodexResumeDoesNotOverrideExplicitCmuxAssignment() {
        let quote: (String) -> String = { "'" + $0 + "'" }
        let rendered = AgentResumeArgv.renderedPortableCodexResumeShellCommand(
            parts: ["env", "-i", "CMUX_CODEX_HOOKS_DISABLED=1", "codex", "resume", "SID"],
            quote: quote
        )

        #expect(rendered.contains("'CMUX_CODEX_HOOKS_DISABLED=1'"), "\(rendered)")
        #expect(!rendered.contains("CMUX_CODEX_HOOKS_DISABLED=\"${CMUX_CODEX_HOOKS_DISABLED:-}\""))
    }

    @Test("Rendered clean environment preserves explicit cmux removals", arguments: [
        ["env", "-i", "-u", "CMUX_CODEX_HOOKS_DISABLED", "codex", "resume", "SID"],
        ["env", "--ignore-environment", "--unset=CMUX_CODEX_HOOKS_DISABLED", "codex", "resume", "SID"],
        ["env", "-iuCMUX_CODEX_HOOKS_DISABLED", "codex", "resume", "SID"],
    ])
    func renderedCodexResumeDoesNotOverrideExplicitCmuxRemoval(parts: [String]) {
        let rendered = AgentResumeArgv.renderedPortableCodexResumeShellCommand(
            parts: parts,
            quote: { "'" + $0 + "'" }
        )

        #expect(!rendered.contains("CMUX_CODEX_HOOKS_DISABLED=\"${CMUX_CODEX_HOOKS_DISABLED:-}\""))
    }

    @Test("Rendered Codex resume supports the legacy clean-environment dash")
    func renderedCodexResumeSupportsLegacyCleanEnvironmentDash() {
        let rendered = AgentResumeArgv.renderedPortableCodexResumeShellCommand(
            parts: ["env", "-", "codex", "resume", "SID"],
            quote: { "'" + $0 + "'" }
        )

        #expect(rendered.hasPrefix("/bin/sh -c "), "\(rendered)")
        #expect(rendered.contains("CMUX_CODEX_WRAPPER_SHIM=\"${CMUX_CODEX_WRAPPER_SHIM:-}\""), "\(rendered)")
    }

    @Test("Rendered clean environment does not treat a chdir operand as an unset option")
    func renderedCodexResumeKeepsCmuxValueWhenChdirOperandLooksLikeUnset() {
        let rendered = AgentResumeArgv.renderedPortableCodexResumeShellCommand(
            parts: ["env", "-i", "--chdir", "-uCMUX_SURFACE_ID", "codex", "resume", "SID"],
            quote: { "'" + $0 + "'" }
        )

        #expect(rendered.contains("CMUX_SURFACE_ID=\"${CMUX_SURFACE_ID:-}\""), "\(rendered)")
    }

    @Test("Codex wrapper starts when an explicit PATH has no Bash")
    func codexWrapperBootstrapDoesNotDependOnChildPath() throws {
        var repositoryRoot = URL(fileURLWithPath: #filePath, isDirectory: false)
        for _ in 0..<6 {
            repositoryRoot.deleteLastPathComponent()
        }
        let wrapper = repositoryRoot.appendingPathComponent(
            "Resources/bin/cmux-codex-wrapper",
            isDirectory: false
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "-i",
            "PATH=/definitely-no-bash",
            "CMUX_CUSTOM_CODEX_PATH=/usr/bin/true",
            wrapper.path,
            "fork",
            "019f53cf-5555-7555-8555-555555555555",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
    }

    @Test("Rendered Codex fork retains cmux tracking across env -i")
    func renderedCodexForkRetainsTrackingAcrossCleanEnvironment() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-codex-env-i-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let output = root.appendingPathComponent("wrapper-environment.txt", isDirectory: false)
        let wrapper = root.appendingPathComponent("codex-wrapper", isDirectory: false)
        try """
        #!/bin/sh
        {
          printf 'path=%s\n' "${PATH:-}"
          printf 'cli=%s\n' "${CMUX_BUNDLED_CLI_PATH:-}"
          printf 'disabled=%s\n' "${CMUX_CODEX_HOOKS_DISABLED:-}"
          printf 'shim=%s\n' "${CMUX_CODEX_WRAPPER_SHIM:-}"
          printf 'socket=%s\n' "${CMUX_SOCKET_PATH:-}"
          printf 'surface=%s\n' "${CMUX_SURFACE_ID:-}"
          printf 'workspace=%s\n' "${CMUX_WORKSPACE_ID:-}"
          printf 'custom=%s\n' "${CMUX_CUSTOM_CODEX_PATH:-}"
          printf 'arguments=%s\n' "$*"
        } > "$TEST_OUTPUT"
        """.write(to: wrapper, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)

        let quote: (String) -> String = { "'" + $0 + "'" }
        let rendered = AgentResumeArgv.renderedPortableCodexResumeShellCommand(
            parts: ["env", "-i", "TEST_OUTPUT=\(output.path)", "/opt/custom/codex", "fork", "SID"],
            quote: quote
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", rendered]
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "CMUX_BUNDLED_CLI_PATH": "/opt/cmux/bin/cmux",
            "CMUX_CODEX_HOOKS_DISABLED": "0",
            "CMUX_CODEX_WRAPPER_SHIM": wrapper.path,
            "CMUX_CODEX_WRAPPER_SHIM_ROOT": root.path,
            "CMUX_SOCKET_PATH": "/tmp/cmux-test.sock",
            "CMUX_SURFACE_ID": "surface-id",
            "CMUX_WORKSPACE_ID": "workspace-id",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let values = try Dictionary(uniqueKeysWithValues: String(contentsOf: output, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { line -> (String, String)? in
                guard let separator = line.firstIndex(of: "=") else { return nil }
                return (
                    String(line[..<separator]),
                    String(line[line.index(after: separator)...])
                )
            })
        #expect(values["path"]?.isEmpty == false)
        #expect(values["cli"] == "/opt/cmux/bin/cmux")
        #expect(values["disabled"] == "0")
        #expect(values["shim"] == wrapper.path)
        #expect(values["socket"] == "/tmp/cmux-test.sock")
        #expect(values["surface"] == "surface-id")
        #expect(values["workspace"] == "workspace-id")
        #expect(values["custom"] == "/opt/custom/codex")
        #expect(values["arguments"] == "fork SID")
    }
}
