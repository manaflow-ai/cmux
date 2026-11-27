@testable import CmuxCloud
import CmuxCloudTui
import Darwin
import Foundation
import Testing

@Suite("Cloud machine link process group", .timeLimit(.minutes(1)))
struct CloudMachineLinkProcessGroupTests {
    @Test("cancelling a link connect stops descendants that ignore SIGTERM and hold its pipes")
    func cancellationStopsDescendantsHoldingPipes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-link-pgroup-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let leaderFIFO = root.appendingPathComponent("leader.pid")
        let helperFIFO = root.appendingPathComponent("helper.pid")
        let client = root.appendingPathComponent("fake-cmux-tui")
        // The helper inherits stdout and stderr and survives SIGTERM, like a
        // dial helper that keeps a wedged attempt's pipes open.
        try """
        #!/bin/sh
        echo $$ > '\(leaderFIFO.path)'
        (
          trap '' TERM
          while true; do sleep 1; done
        ) &
        echo $! > '\(helperFIFO.path)'
        exec /bin/sleep 30
        """.write(to: client, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: client.path)
        for fifo in [leaderFIFO, helperFIFO] {
            try #require(Darwin.mkfifo(fifo.path, 0o600) == 0)
        }
        let leaderFD = Darwin.open(leaderFIFO.path, O_RDWR | O_NONBLOCK)
        try #require(leaderFD >= 0)
        let helperFD = Darwin.open(helperFIFO.path, O_RDWR | O_NONBLOCK)
        try #require(helperFD >= 0)
        var leaderLines = CloudLinkPipe.lines(from: FileHandle(fileDescriptor: leaderFD, closeOnDealloc: true))
            .makeAsyncIterator()
        var helperLines = CloudLinkPipe.lines(from: FileHandle(fileDescriptor: helperFD, closeOnDealloc: true))
            .makeAsyncIterator()

        let link = CloudMachineLink(machineID: "pgroup-machine", clientURL: client, paths: CloudTuiClientPaths(home: root))
        let connect = Task {
            try await link.connect(route: "ws://10.0.0.1:1337/v1/link", session: "main")
        }
        defer { connect.cancel() }
        _ = try #require(await leaderLines.next())
        let helperLine = try #require(await helperLines.next())
        let helperPID = try #require(Int32(helperLine))
        defer { _ = Darwin.kill(helperPID, SIGKILL) }

        connect.cancel()
        do {
            _ = try await connect.value
            Issue.record("a cancelled link connect must throw")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("a cancelled link connect threw \(error) instead of CancellationError")
        }
        #expect(Self.hasStopped(helperPID), "cancellation must stop descendants holding the link pipes before returning")
    }

    @Test("cancelling an SSH link leaves the rest of its group alone")
    func sshCancellationSparesGroupMembers() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-link-pgroup-ssh-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let helperFIFO = root.appendingPathComponent("helper.pid")
        let client = root.appendingPathComponent("fake-cmux-tui")
        // The helper stands in for OpenSSH's ProxyCommand child of a persisted
        // ControlMaster: it stays in the link's group and must outlive the link.
        try """
        #!/bin/sh
        /bin/sleep 30 </dev/null >/dev/null 2>&1 &
        echo $! > '\(helperFIFO.path)'
        exec /bin/sleep 30
        """.write(to: client, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: client.path)
        try #require(Darwin.mkfifo(helperFIFO.path, 0o600) == 0)
        let helperFD = Darwin.open(helperFIFO.path, O_RDWR | O_NONBLOCK)
        try #require(helperFD >= 0)
        var helperLines = CloudLinkPipe.lines(from: FileHandle(fileDescriptor: helperFD, closeOnDealloc: true))
            .makeAsyncIterator()

        let link = CloudMachineLink(machineID: "pgroup-ssh", clientURL: client, paths: CloudTuiClientPaths(home: root))
        let connect = Task {
            try await link.connect(route: "ssh://user@fixture", session: "main")
        }
        defer { connect.cancel() }
        let helperLine = try #require(await helperLines.next())
        let helperPID = try #require(Int32(helperLine))
        defer { _ = Darwin.kill(helperPID, SIGKILL) }

        connect.cancel()
        _ = try? await connect.value
        #expect(!Self.hasStopped(helperPID), "an SSH link must not kill other members of its process group")
    }

    /// A killed descendant may still be an unreaped zombie of launchd.
    private static func hasStopped(_ pid: Int32) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        errno = 0
        let written = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        if written == size { return info.pbi_status == UInt32(SZOMB) }
        return errno == ESRCH
    }
}
