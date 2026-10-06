import Foundation
import Testing
@testable import CmuxNextDaemon

/// `server ensure --terminal-reap-grace-seconds` exists only in cmux-tui
/// builds that list it in root or scoped startup help. The launcher passes it only to such a
/// build, so an older or release client still starts its owner instead of
/// failing with `usage.invalid`.
@Suite struct LauncherReapGraceCapabilityTests {
    /// A stand-in cmux-tui: `--help` lists the reap option only when
    /// `supportsReapGrace`; `server status` reports no owner; `server ensure`
    /// logs its arguments and, like a client without the option, refuses it
    /// with `usage.invalid` when it does not support it.
    func fakeBinary(supportsReapGrace: Bool, scopedStartHelp: Bool = false, in directory: URL) throws -> (binary: URL, log: URL) {
        let log = directory.appendingPathComponent("ensure.log")
        let binary = directory.appendingPathComponent("cmux-tui")
        let started = #"{"generation":"g2","message":"local server started","pid":4343,"session":"s","socket":"/tmp/s.sock","status":"started"}"#
        let refused = #"{"code":"usage.invalid","details":{},"message":"unknown flag --terminal-reap-grace-seconds for this action","retryable":false}"#
        let helpLine = supportsReapGrace ? "  --terminal-reap-grace-seconds <seconds>" : ""
        let script = """
        #!/bin/sh
        case "$1" in
          help)
            if [ "$2" = start ] && [ "\(scopedStartHelp ? "yes" : "no")" = yes ]; then
              printf 'START OPTIONS\\n  --session <name>\\n\(helpLine)\\n'; exit 0
            fi
            exit 2 ;;
          -h|--help)
            if [ "\(scopedStartHelp ? "yes" : "no")" = yes ]; then
              printf 'cmux - terminal multiplexer\\nSCOPES\\n  server  Local owner\\nUse cmux help start for startup options\\n'
            else
              printf 'START OPTIONS\\n  --session <name>\\n\(helpLine)\\n'
            fi
            exit 0 ;;
        esac
        action=""; previous=""; reap=no
        for arg in "$@"; do
          [ "$previous" = server ] && action="$arg"
          [ "$arg" = --terminal-reap-grace-seconds ] && reap=yes
          previous="$arg"
        done
        case "$action" in
          status) echo '{"code":"server.unavailable"}'; exit 3 ;;
          ensure)
            echo "$*" >> '\(log.path)'
            if [ "$reap" = yes ] && [ "\(supportsReapGrace ? "yes" : "no")" = no ]; then echo '\(refused)'; exit 2; fi
            echo '\(started)'; exit 0 ;;
        esac
        exit 2
        """
        try script.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return (binary, log)
    }

    func ensure(supportsReapGrace: Bool, scopedStartHelp: Bool = false) async throws -> (DaemonLauncher.EnsureResult, [String]) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("launcher-reap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (binary, log) = try fakeBinary(supportsReapGrace: supportsReapGrace, scopedStartHelp: scopedStartHelp, in: directory)
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: "s", stateDirectory: directory.appendingPathComponent("state")),
            environment: { ["PATH": "/usr/bin:/bin"] })
        let result = try await launcher.ensure()
        let calls = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        return (result, calls)
    }

    @Test(.timeLimit(.minutes(1))) func aClientWithoutTheReapOptionStillStartsItsOwner() async throws {
        let (result, calls) = try await ensure(supportsReapGrace: false)
        #expect(result.status == "started")
        #expect(calls.count == 1, "one ensure, no retry: \(calls)")
        #expect(calls.allSatisfy { !$0.contains("--terminal-reap-grace-seconds") }, "\(calls)")
    }

    @Test(.timeLimit(.minutes(1))) func aClientWithTheReapOptionGetsTheThirtySecondGrace() async throws {
        let (result, calls) = try await ensure(supportsReapGrace: true)
        #expect(result.status == "started")
        #expect(calls.count == 1, "\(calls)")
        #expect(calls.first?.contains("--terminal-reap-grace-seconds 30") == true, "\(calls)")
    }

    @Test(.timeLimit(.minutes(1))) func aClientWithScopedStartupHelpStillGetsTheGrace() async throws {
        let (result, calls) = try await ensure(supportsReapGrace: true, scopedStartHelp: true)
        #expect(result.status == "started")
        #expect(calls.count == 1, "\(calls)")
        #expect(calls.first?.contains("--terminal-reap-grace-seconds 30") == true, "\(calls)")
    }

    @Test(.timeLimit(.minutes(1))) func scopedHelpWithoutTheOptionStillStartsTheOwner() async throws {
        let (result, calls) = try await ensure(supportsReapGrace: false, scopedStartHelp: true)
        #expect(result.status == "started")
        #expect(calls.count == 1, "\(calls)")
        #expect(calls.allSatisfy { !$0.contains("--terminal-reap-grace-seconds") }, "\(calls)")
    }
}
