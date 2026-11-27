import Foundation
import Testing

@testable import CmuxFoundation

@Suite(.serialized)
struct SSHForegroundAuthenticationLaunchTests {
    private static let workspaceID = "11111111-1111-1111-1111-111111111111"
    private static let socketPath = "/tmp/cmux-foreground-auth-test.sock"

    @Test func readinessReportKeepsTokenOutOfScriptAndArguments() throws {
        let token = "foreground-auth-\(UUID().uuidString)"
        let launch = SSHForegroundAuthenticationLaunch(token: token)
        let script = Self.readinessScript(launch: launch, requireSuccess: true)

        let result = try Self.run(script: script, environment: launch.environment)

        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(!script.contains(token), "The launch script text must not carry the token")
        #expect(launch.environment == [SSHForegroundAuthenticationLaunch.environmentKey: token])
        #expect(result.cliArguments == [
            "--socket", Self.socketPath,
            "rpc", "workspace.remote.foreground_auth_ready", "-",
        ])
        #expect(!result.cliArguments.contains { $0.contains(token) })
        let payload = try #require(
            JSONSerialization.jsonObject(with: Data(result.cliStandardInput.utf8)) as? [String: String]
        )
        #expect(payload == [
            "workspace_id": Self.workspaceID,
            "foreground_auth_token": token,
        ])
        #expect(result.environmentAfterLoad == "unset")
    }

    @Test func readinessReportIncludesResolvedControlPath() throws {
        let token = "foreground-auth-\(UUID().uuidString)"
        let launch = SSHForegroundAuthenticationLaunch(token: token)
        let script = Self.readinessScript(
            launch: launch,
            controlPath: "/tmp/cmux-ssh-501-control",
            requireSuccess: true
        )

        let result = try Self.run(script: script, environment: launch.environment)

        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let payload = try #require(
            JSONSerialization.jsonObject(with: Data(result.cliStandardInput.utf8)) as? [String: String]
        )
        #expect(payload["foreground_auth_token"] == token)
        #expect(payload["control_path"] == "/tmp/cmux-ssh-501-control")
    }

    @Test func launchScriptMarkerMatchesOnlyItsOwnToken() {
        let launch = SSHForegroundAuthenticationLaunch(token: "foreground-auth-\(UUID().uuidString)")
        let otherLaunch = SSHForegroundAuthenticationLaunch(token: "foreground-auth-\(UUID().uuidString)")
        let script = launch.tokenLoadShellLines(into: "cmux_test_token").joined(separator: " ")

        #expect(launch.isExpected(by: script))
        #expect(!otherLaunch.isExpected(by: script), "A script built for another token must not receive this one")
        #expect(!launch.isExpected(by: "ssh example.test"))
        #expect(!launch.commandMarker.contains(launch.token))
    }

    @Test(arguments: [(true, Int32(255)), (false, Int32(0))])
    func missingTokenSkipsReadinessReport(requireSuccess: Bool, expectedStatus: Int32) throws {
        let launch = SSHForegroundAuthenticationLaunch(token: "foreground-auth-\(UUID().uuidString)")
        let script = Self.readinessScript(launch: launch, requireSuccess: requireSuccess)

        let result = try Self.run(script: script, environment: [:])

        #expect(result.status == expectedStatus, Comment(rawValue: result.stderr))
        #expect(result.cliArguments.isEmpty, "A missing token must not reach the local socket")
        #expect(result.stderr.contains("foreground authentication token"))
    }

    private static func readinessScript(
        launch: SSHForegroundAuthenticationLaunch,
        controlPath: String? = nil,
        requireSuccess: Bool
    ) -> String {
        var lines = ["cmux_test_cli=\"$CMUX_TEST_CLI\""]
        if let controlPath {
            lines.append("cmux_test_control_path='\(controlPath)'")
        }
        lines += launch.tokenLoadShellLines(into: "cmux_test_token")
        lines.append(
            "printf '%s' \"${\(SSHForegroundAuthenticationLaunch.environmentKey)-unset}\" " +
                "> \"$CMUX_TEST_ENVIRONMENT_LOG\""
        )
        lines += SSHForegroundAuthenticationLaunch.readyShellLines(
            tokenVariable: "cmux_test_token",
            payloadVariable: "cmux_test_payload",
            cliVariable: "cmux_test_cli",
            socketVariable: "CMUX_SOCKET_PATH",
            controlPathVariable: controlPath == nil ? nil : "cmux_test_control_path",
            requireSuccess: requireSuccess
        )
        lines.append("exit 0")
        return lines.joined(separator: "\n")
    }

    private struct RunResult {
        let status: Int32
        let stderr: String
        let cliArguments: [String]
        let cliStandardInput: String
        let environmentAfterLoad: String
    }

    private static func run(script: String, environment: [String: String]) throws -> RunResult {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-foreground-auth-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let fakeCLI = root.appendingPathComponent("cmux")
        let argumentsLog = root.appendingPathComponent("arguments.log")
        let standardInputLog = root.appendingPathComponent("stdin.log")
        let environmentLog = root.appendingPathComponent("environment.log")
        try """
        #!/bin/sh
        for argument in "$@"; do printf '%s\\n' "$argument"; done > "$CMUX_TEST_ARGUMENTS_LOG"
        /bin/cat > "$CMUX_TEST_STDIN_LOG"
        exit 0
        """.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCLI.path)

        var processEnvironment = [
            "PATH": "/usr/bin:/bin",
            "CMUX_WORKSPACE_ID": workspaceID,
            "CMUX_SOCKET_PATH": socketPath,
            "CMUX_TEST_CLI": fakeCLI.path,
            "CMUX_TEST_ARGUMENTS_LOG": argumentsLog.path,
            "CMUX_TEST_STDIN_LOG": standardInputLog.path,
            "CMUX_TEST_ENVIRONMENT_LOG": environmentLog.path,
        ]
        processEnvironment.merge(environment) { _, launchValue in launchValue }

        let process = Process()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.environment = processEnvironment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe
        try process.run()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let arguments = (try? String(contentsOf: argumentsLog, encoding: .utf8)) ?? ""
        return RunResult(
            status: process.terminationStatus,
            stderr: String(decoding: stderrData, as: UTF8.self),
            cliArguments: arguments.split(separator: "\n").map(String.init),
            cliStandardInput: (try? String(contentsOf: standardInputLog, encoding: .utf8)) ?? "",
            environmentAfterLoad: (try? String(contentsOf: environmentLog, encoding: .utf8)) ?? ""
        )
    }
}
