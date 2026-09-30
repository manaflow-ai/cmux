@testable import CmuxCloud
import CmuxCloudTui
import Foundation
import Testing

/// A link client that exits before naming its socket fails the connect with its
/// own exit status and stderr. The stderr reader runs in its own task, so the
/// last lines can still be in flight when the process exits.
@Suite("Cloud machine link exit diagnostics")
struct CloudMachineLinkExitDiagnosticsTests {
    @Test("An exit error carries stderr written until the pipe closes")
    func exitErrorWaitsForStderrToClose() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-link-exit-stderr-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = root.appendingPathComponent("fake-cmux-tui")
        // The client exits at once. Once it is reaped, a child it started closes
        // stdout and writes the last stderr line a moment later. Closing stdout
        // earlier would let connect terminate the unreaped client's process
        // group, child included, before the line is written. Without the wait,
        // connect builds the error within milliseconds of stdout closing.
        try """
        #!/bin/sh
        (while kill -0 $$ 2>/dev/null; do sleep 0.01; done
         exec >/dev/null; sleep 0.1; echo 'cmux-tui: route refused' >&2) &
        exit 2
        """.write(to: client, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: client.path)
        let link = CloudMachineLink(machineID: "test-machine", clientURL: client, paths: CloudTuiClientPaths(home: root))

        do {
            _ = try await link.connect(route: "ws://10.0.0.1:1337/v1/link", session: "main", carrier: true)
            Issue.record("a client that exits before its socket line must fail the connect")
        } catch CloudMachineLink.LinkError.exited(let status, let output) {
            #expect(status == 2)
            #expect(output.contains("route refused"), "stderr written before the pipe closed must reach the error: \(output)")
        } catch {
            Issue.record("expected LinkError.exited, got \(error)")
        }
    }

    @Test("An exit after connect refines its error with late stderr")
    func connectedExitRefinesLateStderr() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-link-connected-exit-stderr-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = root.appendingPathComponent("fake-cmux-tui")
        try """
        #!/bin/sh
        printf '%s\n' '{"event":"connection-snapshot","local_socket":"/tmp/cmux-link-connected-exit-test-\(UUID().uuidString.lowercased()).sock"}'
        (sleep 0.2; echo 'cmux-tui: late route refused' >&2) &
        sleep 0.05
        exit 2
        """.write(to: client, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: client.path)
        let link = CloudMachineLink(machineID: "test-machine", clientURL: client, paths: CloudTuiClientPaths(home: root))

        do {
            _ = try await link.connect(route: "ws://10.0.0.1:1337/v1/link", session: "main", carrier: true)
        } catch {
            Issue.record("the socket line should let connect return before the client exits: \(error)")
            return
        }
        for _ in 0..<100 {
            if let error = await link.lastError, error.contains("late route refused") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let error = await link.lastError
        #expect(error?.contains("late route refused") == true, "the connected exit should include late stderr: \(error ?? "nil")")
    }

    @Test("A retry reports only the current client's stderr")
    func retryDoesNotReusePreviousStderr() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-link-retry-stderr-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = root.appendingPathComponent("fake-cmux-tui")
        let marker = root.appendingPathComponent("attempt")
        try """
        #!/bin/sh
        if [ -e '\(marker.path)' ]; then
            echo 'cmux-tui: second route refused' >&2
        else
            touch '\(marker.path)'
            echo 'cmux-tui: first route refused' >&2
        fi
        exit 2
        """.write(to: client, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: client.path)
        let link = CloudMachineLink(machineID: "test-machine", clientURL: client, paths: CloudTuiClientPaths(home: root))

        do {
            _ = try await link.connect(route: "ws://10.0.0.1:1337/v1/link", session: "main", carrier: true)
            Issue.record("the first client must fail before naming its socket")
        } catch CloudMachineLink.LinkError.exited(_, let output) {
            #expect(output.contains("first route refused"))
        } catch {
            Issue.record("expected first LinkError.exited, got \(error)")
        }

        do {
            _ = try await link.connect(route: "ws://10.0.0.1:1337/v1/link", session: "main", carrier: true)
            Issue.record("the retry client must fail before naming its socket")
        } catch CloudMachineLink.LinkError.exited(_, let output) {
            #expect(output.contains("second route refused"))
            #expect(!output.contains("first route refused"), "a retry must not report stale stderr: \(output)")
        } catch {
            Issue.record("expected retry LinkError.exited, got \(error)")
        }
    }

    @Test("An exit after the socket line carries stderr written until the pipe closes")
    func exitAfterSocketLineWaitsForStderrToClose() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-link-exit-after-socket-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = root.appendingPathComponent("fake-cmux-tui")
        // The client exits at once. Once it is reaped, a child it started names
        // the socket, closes stdout and writes the last stderr line a moment later.
        try """
        #!/bin/sh
        (while kill -0 $$ 2>/dev/null; do sleep 0.01; done
         printf '%s\\n' '{"event":"connection-snapshot","local_socket":"/tmp/cmux-link-exit-test.sock"}'
         exec >/dev/null; sleep 0.1; echo 'cmux-tui: route refused' >&2) &
        exit 2
        """.write(to: client, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: client.path)
        let link = CloudMachineLink(machineID: "test-machine", clientURL: client, paths: CloudTuiClientPaths(home: root))

        do {
            _ = try await link.connect(route: "ws://10.0.0.1:1337/v1/link", session: "main", carrier: true)
            Issue.record("a client that exits after its socket line must fail the connect")
        } catch CloudMachineLink.LinkError.exited(let status, let output) {
            #expect(status == 2)
            #expect(output.contains("route refused"), "stderr written before the pipe closed must reach the error: \(output)")
        } catch {
            Issue.record("expected LinkError.exited, got \(error)")
        }
    }
}
