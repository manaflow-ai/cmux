import Foundation
import Testing

@testable import CmuxWindowing

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

    @Test func prependsSocketFlagAndForwardsArguments() async throws {
        let script = try makeScript(#"printf '%s\n' "$@""#)
        let router = MultiWindowRouter(
            cliURL: script,
            socketPath: "/tmp/route.sock",
            environment: [:]
        )
        let result = try await router.route(arguments: ["list-workspaces", "--window", "ABC"])
        #expect(result.terminationStatus == 0)
        #expect(result.stdout == "--socket\n/tmp/route.sock\nlist-workspaces\n--window\nABC\n")
        #expect(result.stderr == "")
    }

    @Test func capturesStderrAndNonZeroExitStatus() async throws {
        let script = try makeScript("echo oops 1>&2; exit 3")
        let router = MultiWindowRouter(
            cliURL: script,
            socketPath: "/tmp/route.sock",
            environment: [:]
        )
        let result = try await router.route(arguments: [])
        #expect(result.terminationStatus == 3)
        #expect(result.stdout == "")
        #expect(result.stderr == "oops\n")
    }

    @Test func childEnvironmentIsExactlyTheInjectedOne() async throws {
        // The legacy code sets `process.environment` wholesale: injected keys
        // are visible and the parent's environment is NOT inherited.
        let script = try makeScript(#"printf '%s|%s' "$CMUX_TEST_MARKER" "${HOME:-unset}""#)
        let router = MultiWindowRouter(
            cliURL: script,
            socketPath: "/tmp/route.sock",
            environment: ["CMUX_TEST_MARKER": "marker-value"]
        )
        let result = try await router.route(arguments: [])
        #expect(result.terminationStatus == 0)
        #expect(result.stdout == "marker-value|unset")
    }

    @Test func throwsLaunchErrorPreservingUnderlyingDescription() async {
        let router = MultiWindowRouter(
            cliURL: URL(fileURLWithPath: "/nonexistent/cmux-cli-\(UUID().uuidString)"),
            socketPath: "/tmp/route.sock",
            environment: [:]
        )
        do {
            _ = try await router.route(arguments: ["ping"])
            Issue.record("route should throw when the CLI cannot launch")
        } catch let error as MultiWindowRouteLaunchError {
            #expect(!error.description.isEmpty)
            // The legacy capture writes String(describing: error); the launch
            // error renders as its preserved underlying description so that
            // encoding stays byte-identical.
            #expect(String(describing: error) == error.description)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func captureEncodingFoldsLaunchFailureIntoLegacyResult() async {
        // The UI-test capture path must keep running later calls after an
        // earlier launch failure, so the convenience folds the throw into the
        // legacy "-1" encoding instead of propagating it.
        let router = MultiWindowRouter(
            cliURL: URL(fileURLWithPath: "/nonexistent/cmux-cli-\(UUID().uuidString)"),
            socketPath: "/tmp/route.sock",
            environment: [:]
        )
        let result = await router.routeCapturingLaunchFailure(arguments: ["ping"])
        #expect(result.terminationStatus == -1)
        #expect(result.stdout == "")
        #expect(!result.stderr.isEmpty)
    }

    @Test func nonUTF8OutputCollapsesToEmptyString() async throws {
        let script = try makeScript(#"printf '\377\376'"#)
        let router = MultiWindowRouter(
            cliURL: script,
            socketPath: "/tmp/route.sock",
            environment: [:]
        )
        let result = try await router.route(arguments: [])
        #expect(result.terminationStatus == 0)
        #expect(result.stdout == "")
    }

    @Test func outputLargerThanPipeBufferDoesNotDeadlock() async throws {
        // 256 KiB of stdout exceeds the 64 KiB pipe buffer; the concurrent
        // stream readers must drain it while the child runs, otherwise the
        // child blocks on a full pipe and never exits.
        let script = try makeScript("/usr/bin/head -c 262144 /dev/zero | /usr/bin/tr '\\0' 'a'")
        let router = MultiWindowRouter(
            cliURL: script,
            socketPath: "/tmp/route.sock",
            environment: [:]
        )
        let result = try await router.route(arguments: [])
        #expect(result.terminationStatus == 0)
        #expect(result.stdout.count == 262_144)
        #expect(result.stdout.allSatisfy { $0 == "a" })
    }
}
