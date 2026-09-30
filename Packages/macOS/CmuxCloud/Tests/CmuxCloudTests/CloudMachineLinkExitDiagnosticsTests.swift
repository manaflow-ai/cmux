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
        // The client exits at once. A child it started closes stdout and writes
        // the last stderr line a moment later, while it still holds that pipe.
        try """
        #!/bin/sh
        (exec >/dev/null; sleep 0.3; echo 'cmux-tui: route refused' >&2) &
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
}
