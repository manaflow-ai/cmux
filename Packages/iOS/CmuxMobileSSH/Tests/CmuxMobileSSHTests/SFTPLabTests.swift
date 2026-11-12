import CmuxMobileSSH
import Foundation
import Testing

/// Live SFTP tests against the local lab sshd (`CMUX_SSH_LAB`, port 2222).
/// Serialized so this suite holds one handshake at a time; the lab sshd drops
/// connections past `MaxStartups` (10) when every suite connects at once.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_SSH_LAB"] != nil))
struct SFTPLabTests {
    let lab = ProcessInfo.processInfo.environment["CMUX_SSH_LAB"] ?? ""

    /// Connects, opens SFTP, and runs `body` inside a fresh `/tmp` directory
    /// that is removed afterwards.
    private func withSFTP(_ body: (SFTPClient, String) async throws -> Void) async throws {
        let text = try String(contentsOfFile: "\(lab)/client_ed25519", encoding: .utf8)
        let connection = try await SSHConnection.connect(
            to: SSHEndpoint(host: "127.0.0.1", port: 2222, username: NSUserName()),
            credentials: [.privateKey(try SSHParsedPrivateKey(openSSH: text).key)],
            hostKeyVerifier: RecordingVerifier(accept: true)
        )
        let sftp = try await SFTPClient.open(on: connection)
        let root = "/tmp/cmux-sftp-test-\(UUID().uuidString)"
        try await sftp.mkdir(root)
        do {
            try await body(sftp, root)
        } catch {
            _ = try? shell("rm -rf '\(root)'")
            await sftp.close()
            await connection.close()
            throw error
        }
        _ = try? shell("rm -rf '\(root)'")
        await sftp.close()
        await connection.close()
    }

    @Test func realpathResolvesHome() async throws {
        try await withSFTP { sftp, _ in
            #expect(await sftp.serverVersion == 3)
            let home = try await sftp.realpath(".")
            #expect(home.hasPrefix("/"))
            #expect(home == (try shell("cd ~ && pwd -P")) || home == NSHomeDirectory())
        }
    }

    @Test func mkdirAndListDirectory() async throws {
        try await withSFTP { sftp, root in
            try await sftp.mkdir("\(root)/sub")
            try await sftp.writeFile("\(root)/a.txt", data: Data("alpha".utf8))
            let entries = try await sftp.listDirectory(root).sorted { $0.name < $1.name }
            #expect(entries.map(\.name) == ["a.txt", "sub"])
            #expect(entries[0].isDirectory == false)
            #expect(entries[0].attributes.isRegularFile)
            #expect(entries[0].attributes.size == 5)
            #expect(entries[1].isDirectory)
            #expect(entries[1].attributes.modificationTime != nil)
        }
    }

    @Test func uploadAndDownloadOneMiBRoundTrips() async throws {
        try await withSFTP { sftp, root in
            let bytes = Data((0..<(1 << 20)).map { _ in UInt8.random(in: 0...255) })
            let local = FileManager.default.temporaryDirectory.appendingPathComponent("sftp-up-\(UUID().uuidString)")
            let back = FileManager.default.temporaryDirectory.appendingPathComponent("sftp-down-\(UUID().uuidString)")
            defer {
                try? FileManager.default.removeItem(at: local)
                try? FileManager.default.removeItem(at: back)
            }
            try bytes.write(to: local)

            let uploaded = ProgressLog()
            try await sftp.upload(from: local, to: "\(root)/big.bin") { uploaded.record($0) }
            #expect(try await sftp.stat("\(root)/big.bin").size == UInt64(bytes.count))
            #expect(uploaded.last?.bytesTransferred == UInt64(bytes.count))
            #expect(uploaded.last?.totalBytes == UInt64(bytes.count))

            let downloaded = ProgressLog()
            try await sftp.download("\(root)/big.bin", to: back) { downloaded.record($0) }
            #expect(try Data(contentsOf: back) == bytes)
            #expect(downloaded.last?.bytesTransferred == UInt64(bytes.count))

            // Existing local contents are replaced, not merged.
            try Data(repeating: 7, count: 3 << 20).write(to: back)
            try await sftp.download("\(root)/big.bin", to: back)
            #expect(try Data(contentsOf: back) == bytes)
        }
    }

    @Test func readFileSmallAndTruncated() async throws {
        try await withSFTP { sftp, root in
            try await sftp.writeFile("\(root)/small.txt", data: Data("hello sftp\n".utf8))
            #expect(try await sftp.readFile("\(root)/small.txt") == Data("hello sftp\n".utf8))
            #expect(try await sftp.readFile("\(root)/small.txt", maxBytes: 5) == Data("hello".utf8))
            try await sftp.writeFile("\(root)/empty", data: Data())
            #expect(try await sftp.readFile("\(root)/empty").isEmpty)
        }
    }

    @Test func renameStatRemoveRmdir() async throws {
        try await withSFTP { sftp, root in
            try await sftp.writeFile("\(root)/old", data: Data(repeating: 1, count: 1234))
            try await sftp.rename("\(root)/old", to: "\(root)/new")
            #expect(try await sftp.stat("\(root)/new").size == 1234)
            #expect(try await sftp.lstat("\(root)/new").isRegularFile)
            await #expect(throws: SFTPError.noSuchFile) { try await sftp.stat("\(root)/old") }

            try await sftp.remove("\(root)/new")
            await #expect(throws: SFTPError.noSuchFile) { try await sftp.stat("\(root)/new") }

            try await sftp.mkdir("\(root)/dir")
            try await sftp.rmdir("\(root)/dir")
            #expect(try await sftp.listDirectory(root).isEmpty)
        }
    }

    @Test func missingPathsReportNoSuchFile() async throws {
        try await withSFTP { sftp, root in
            await #expect(throws: SFTPError.noSuchFile) { try await sftp.readFile("\(root)/nope") }
            await #expect(throws: SFTPError.noSuchFile) { try await sftp.listDirectory("\(root)/nope") }
            await #expect(throws: SFTPError.noSuchFile) { try await sftp.remove("\(root)/nope") }
            // The client stays usable after errors.
            let entries = try await sftp.listDirectory(root)
            #expect(entries.isEmpty)
        }
    }

    @Test func closedClientFailsWithConnectionLost() async throws {
        try await withSFTP { sftp, root in
            await sftp.close()
            await #expect(throws: SFTPError.connectionLost) { try await sftp.stat(root) }
        }
    }
}

/// Thread-safe sink for progress callbacks.
private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SFTPTransferProgress] = []

    func record(_ value: SFTPTransferProgress) {
        lock.withLock { values.append(value) }
    }

    var last: SFTPTransferProgress? { lock.withLock { values.last } }
}
