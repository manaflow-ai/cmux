import Foundation
import Testing

@testable import CmuxIPCService

@Suite struct MultiWindowRouterTests {
    /// Writes an executable `/bin/sh` script into a temp directory and returns
    /// its URL, so each test exercises the real spawn/capture path against a
    /// controlled CLI stand-in.
    private func makeScript(_ body: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CmuxIPCServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("fake-cmux")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test func prependsSocketFlagAndForwardsArguments() throws {
        let script = try makeScript(#"printf '%s\n' "$@""#)
        let router = MultiWindowRouter(
            cliURL: script,
            socketPath: "/tmp/route.sock",
            environment: [:]
        )
        let result = router.route(arguments: ["list-workspaces", "--window", "ABC"])
        #expect(result.status == "0")
        #expect(result.stdout == "--socket\n/tmp/route.sock\nlist-workspaces\n--window\nABC\n")
        #expect(result.stderr == "")
    }

    @Test func capturesStderrAndNonZeroExitStatus() throws {
        let script = try makeScript("echo oops 1>&2; exit 3")
        let router = MultiWindowRouter(
            cliURL: script,
            socketPath: "/tmp/route.sock",
            environment: [:]
        )
        let result = router.route(arguments: [])
        #expect(result.status == "3")
        #expect(result.stdout == "")
        #expect(result.stderr == "oops\n")
    }

    @Test func childEnvironmentIsExactlyTheInjectedOne() throws {
        // The legacy code sets `process.environment` wholesale: injected keys
        // are visible and the parent's environment is NOT inherited.
        let script = try makeScript(#"printf '%s|%s' "$CMUX_TEST_MARKER" "${HOME:-unset}""#)
        let router = MultiWindowRouter(
            cliURL: script,
            socketPath: "/tmp/route.sock",
            environment: ["CMUX_TEST_MARKER": "marker-value"]
        )
        let result = router.route(arguments: [])
        #expect(result.status == "0")
        #expect(result.stdout == "marker-value|unset")
    }

    @Test func encodesLaunchFailureAsLegacyResult() {
        let router = MultiWindowRouter(
            cliURL: URL(fileURLWithPath: "/nonexistent/cmux-cli-\(UUID().uuidString)"),
            socketPath: "/tmp/route.sock",
            environment: [:]
        )
        let result = router.route(arguments: ["ping"])
        #expect(result.status == "-1")
        #expect(result.stdout == "")
        #expect(!result.stderr.isEmpty)
    }

    @Test func nonUTF8OutputCollapsesToEmptyString() throws {
        let script = try makeScript(#"printf '\377\376'"#)
        let router = MultiWindowRouter(
            cliURL: script,
            socketPath: "/tmp/route.sock",
            environment: [:]
        )
        let result = router.route(arguments: [])
        #expect(result.status == "0")
        #expect(result.stdout == "")
    }
}
