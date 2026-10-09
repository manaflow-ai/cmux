@testable import CmuxMobileSSH
import Foundation
import Testing

/// `SFTPClient` against the in-memory v3 server: the operations the phone's
/// SFTP browser and transfers use, with no sshd.
struct SFTPClientFakeChannelTests {
    private func client(_ server: FakeSFTPServer) async throws -> SFTPClient {
        try await SFTPClient.open(channel: server)
    }

    private func temporaryFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sftp-fake-\(UUID().uuidString)")
        try data.write(to: url)
        return url
    }

    private static func pattern(_ count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
    }

    @Test func handshakeAndRealpath() async throws {
        let sftp = try await client(FakeSFTPServer())
        #expect(await sftp.serverVersion == 3)
        #expect(try await sftp.realpath(".") == "/home/me")
    }

    @Test func listsWithoutDotEntries() async throws {
        let server = FakeSFTPServer()
        server.set("/home/me/a.txt", .file(Data("a".utf8)))
        server.set("/home/me/src", .directory)
        let entries = try await client(server).listDirectory("/home/me")
        #expect(entries.map(\.name) == ["a.txt", "src"])
        #expect(entries.first { $0.name == "src" }?.isDirectory == true)
        #expect(entries.first { $0.name == "a.txt" }?.attributes.size == 1)
    }

    @Test func statReportsTypeAndMissingPath() async throws {
        let server = FakeSFTPServer()
        server.set("/home/me/f", .file(Data(count: 10)))
        let sftp = try await client(server)
        let attributes = try await sftp.stat("/home/me/f")
        #expect(attributes.isRegularFile)
        #expect(attributes.size == 10)
        await #expect(throws: SFTPError.noSuchFile) { try await sftp.stat("/home/me/missing") }
    }

    @Test func writeThenReadRoundTripsAcrossManyChunks() async throws {
        let sftp = try await client(FakeSFTPServer())
        let data = Self.pattern(SFTPClient.chunkSize * 20 + 123)
        try await sftp.writeFile("/home/me/big.bin", data: data)
        #expect(try await sftp.readFile("/home/me/big.bin") == data)
    }

    @Test func shortReadsAreRequestedAgain() async throws {
        let server = FakeSFTPServer()
        let data = Self.pattern(SFTPClient.chunkSize * 3)
        server.set("/home/me/f", .file(data))
        server.state.withLock { $0.maxRead = 1000 }
        #expect(try await client(server).readFile("/home/me/f") == data)
    }

    @Test func mkdirRenameRemoveRmdir() async throws {
        let server = FakeSFTPServer()
        let sftp = try await client(server)
        try await sftp.mkdir("/home/me/dir")
        try await sftp.writeFile("/home/me/dir/x", data: Data("x".utf8))
        try await sftp.rename("/home/me/dir/x", to: "/home/me/dir/y")
        #expect(server.node("/home/me/dir/x") == nil)
        #expect(server.node("/home/me/dir/y") == .file(Data("x".utf8)))
        try await sftp.remove("/home/me/dir/y")
        try await sftp.rmdir("/home/me/dir")
        #expect(server.node("/home/me/dir") == nil)
    }

    @Test func serverRefusalsMapToErrors() async throws {
        let server = FakeSFTPServer()
        server.set("/root-only", .file(Data()))
        let sftp = try await client(server)
        await #expect(throws: SFTPError.permissionDenied) { try await sftp.rename("/root-only", to: "/home/me/z") }
        await #expect(throws: SFTPError.noSuchFile) { try await sftp.remove("/home/me/nothing") }
        await #expect(throws: SFTPError.failure("exists")) { try await sftp.mkdir("/home/me") }
    }

    @Test func downloadResumesFromLocalBytes() async throws {
        let server = FakeSFTPServer()
        let data = Self.pattern(SFTPClient.chunkSize * 4 + 9)
        server.set("/home/me/f", .file(data))
        let local = try temporaryFile(data.prefix(SFTPClient.chunkSize + 5))
        defer { try? FileManager.default.removeItem(at: local) }
        try await client(server).download("/home/me/f", to: local, resumeFrom: UInt64(SFTPClient.chunkSize + 5))
        #expect(try Data(contentsOf: local) == data)
    }

    @Test func downloadFromZeroReplacesTheLocalFile() async throws {
        let server = FakeSFTPServer()
        server.set("/home/me/f", .file(Data("new".utf8)))
        let local = try temporaryFile(Data("old contents".utf8))
        defer { try? FileManager.default.removeItem(at: local) }
        try await client(server).download("/home/me/f", to: local)
        #expect(try Data(contentsOf: local) == Data("new".utf8))
    }

    @Test func uploadResumesWithoutTruncating() async throws {
        let server = FakeSFTPServer()
        let data = Self.pattern(SFTPClient.chunkSize * 2 + 77)
        let split = SFTPClient.chunkSize + 3
        server.set("/home/me/up", .file(data.prefix(split)))
        let local = try temporaryFile(data)
        defer { try? FileManager.default.removeItem(at: local) }
        try await client(server).upload(from: local, to: "/home/me/up", resumeFrom: UInt64(split))
        #expect(server.node("/home/me/up") == .file(data))
        let (writes, flags) = server.state.withLock { ($0.writes, $0.openFlags) }
        #expect(writes.first?.offset == UInt64(split))
        #expect(flags.last.map { $0 & 0x10 } == 0)
    }

    @Test func uploadReportsProgressToTheEnd() async throws {
        let server = FakeSFTPServer()
        let data = Self.pattern(SFTPClient.chunkSize * 3)
        let local = try temporaryFile(data)
        defer { try? FileManager.default.removeItem(at: local) }
        let last = Locked<SFTPTransferProgress?>(nil)
        try await client(server).upload(from: local, to: "/home/me/p") { progress in last.withLock { $0 = progress } }
        #expect(last.withLock { $0 } == SFTPTransferProgress(bytesTransferred: UInt64(data.count), totalBytes: UInt64(data.count)))
    }

    @Test func droppedChannelFailsPendingAndLaterCalls() async throws {
        let server = FakeSFTPServer()
        let sftp = try await client(server)
        server.state.withLock { $0.dropAfterRequests = $0.requests }
        await #expect(throws: SFTPError.connectionLost) { try await sftp.stat("/home/me") }
        await #expect(throws: SFTPError.connectionLost) { try await sftp.listDirectory("/home/me") }
    }

    @Test func cancelledDownloadStopsBetweenChunksAndLeavesTheClientUsable() async throws {
        let server = FakeSFTPServer()
        server.set("/home/me/f", .file(Self.pattern(SFTPClient.chunkSize * 64)))
        let sftp = try await client(server)
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("sftp-fake-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: local) }
        await #expect(throws: CancellationError.self) {
            try await sftp.download("/home/me/f", to: local) { _ in withUnsafeCurrentTask { $0?.cancel() } }
        }
        #expect(try await sftp.realpath(".") == "/home/me")
    }
}
