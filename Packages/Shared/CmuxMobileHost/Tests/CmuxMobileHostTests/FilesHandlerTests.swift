import CmuxLink
import CmuxMobileHost
import CmuxMobileWire
import Foundation
import Testing

@Suite("Files handlers over the session")
struct FilesHandlerTests {
    // MARK: Upload

    @Test func uploadLandsInTheInboxAfterTheDigestVerifies() async throws {
        let f = try FilesFixture()
        defer { f.remove() }
        let h = try await PhoneHarness(handlers: f.files.registering())
        defer { Task { await h.shutdown() } }
        try await h.hello()
        let data = FilesFixture.bytes(200_000)
        let (channel, opened) = try await h.open(.filesUpload, id: 1, params: FilesFixture.uploadParams(data))
        #expect(opened["t"] == "channel.opened")
        #expect(opened["params"]?["offset"] == .int(0))
        try await send(data, from: 0, on: channel)
        try await channel.send(message: FilesUploadEnd(sha256: FilesFixture.sha256(data)).message)
        let done = try #require(FilesUploadDone(try message(await PhoneHarness.nextJSON(channel))))
        #expect(done.size == UInt64(data.count))
        #expect(done.path.hasSuffix("/Downloads/cmux-phone/photo.jpg"))
        #expect(try Data(contentsOf: URL(fileURLWithPath: done.path)) == data)
    }

    @Test func aReopenedUploadResumesFromTheMacsBytes() async throws {
        let f = try FilesFixture()
        defer { f.remove() }
        let h = try await PhoneHarness(handlers: f.files.registering())
        defer { Task { await h.shutdown() } }
        try await h.hello()
        let data = FilesFixture.bytes(300_000)
        let params = FilesFixture.uploadParams(data)
        let (first, _) = try await h.open(.filesUpload, id: 1, params: params)
        try await send(data.prefix(120_000), from: 0, on: first)
        try await first.link.flush()
        await first.link.close()
        let (second, opened) = try await reopen(h, id: 3, params: params, expecting: 120_000)
        #expect(opened["resumed"] == .bool(true))
        try await send(data.suffix(from: 120_000), from: 120_000, on: second)
        try await second.send(message: FilesUploadEnd(sha256: FilesFixture.sha256(data)).message)
        let done = try #require(FilesUploadDone(try message(await PhoneHarness.nextJSON(second))))
        #expect(try Data(contentsOf: URL(fileURLWithPath: done.path)) == data)
    }

    @Test func aDigestMismatchDeletesThePartial() async throws {
        let f = try FilesFixture()
        defer { f.remove() }
        let h = try await PhoneHarness(handlers: f.files.registering())
        defer { Task { await h.shutdown() } }
        try await h.hello()
        let data = FilesFixture.bytes(50_000)
        let wrong = FilesFixture.sha256(Data("other".utf8))
        let params = FilesFixture.uploadParams(data, sha: wrong)
        let (channel, _) = try await h.open(.filesUpload, id: 1, params: params)
        try await send(data, from: 0, on: channel)
        try await channel.send(message: FilesUploadEnd(sha256: wrong).message)
        let closed = try await PhoneHarness.nextJSON(channel)
        #expect(closed["t"] == "channel.closed")
        #expect(closed["code"] == "files.digest_mismatch")
        let (_, opened) = try await h.open(.filesUpload, id: 3, params: params)
        #expect(opened["params"]?["offset"] == .int(0))
    }

    @Test func aChunkAtTheWrongOffsetClosesTheChannel() async throws {
        let f = try FilesFixture()
        defer { f.remove() }
        let h = try await PhoneHarness(handlers: f.files.registering())
        defer { Task { await h.shutdown() } }
        try await h.hello()
        let data = FilesFixture.bytes(10_000)
        let (channel, _) = try await h.open(.filesUpload, id: 1, params: FilesFixture.uploadParams(data))
        try await channel.send(binary: FileChunk(offset: 4096, data: data.prefix(100)).encoded)
        let closed = try await PhoneHarness.nextJSON(channel)
        #expect(closed["code"] == "proto.bad_record")
    }

    @Test func uploadsOutsideTheRootsOrTooLargeAreRefused() async throws {
        let f = try FilesFixture(maxUploadBytes: 1000)
        defer { f.remove() }
        let h = try await PhoneHarness(handlers: f.files.registering())
        defer { Task { await h.shutdown() } }
        try await h.hello()
        let data = FilesFixture.bytes(100)
        let escape = FilesFixture.uploadParams(data, dest: FilesUploadDestination(kind: .path, path: "~/src/proj/../.."))
        let (_, refused) = try await h.open(.filesUpload, id: 1, params: escape)
        #expect(refused["t"] == "channel.refused")
        #expect(refused["code"] == "files.forbidden")
        let home = FilesFixture.uploadParams(data, dest: FilesUploadDestination(kind: .path, path: f.home.path))
        #expect(try await h.open(.filesUpload, id: 3, params: home).1["code"] == "files.forbidden")
        let big = FilesFixture.uploadParams(FilesFixture.bytes(2000))
        let (_, tooLarge) = try await h.open(.filesUpload, id: 5, params: big)
        #expect(tooLarge["code"] == "files.too_large")
        #expect(tooLarge["details"]?["reason"] == "file")
        let inside = FilesFixture.uploadParams(data, name: "../evil.sh", dest: FilesUploadDestination(kind: .path, path: "~/src/proj"))
        let (channel, opened) = try await h.open(.filesUpload, id: 7, params: inside)
        #expect(opened["t"] == "channel.opened")
        try await send(data, from: 0, on: channel)
        try await channel.send(message: FilesUploadEnd(sha256: FilesFixture.sha256(data)).message)
        let done = try #require(FilesUploadDone(try message(await PhoneHarness.nextJSON(channel))))
        #expect(done.path.hasSuffix("/src/proj/evil.sh"))
    }

    @Test func parallelUploadsCannotOvercommitTheQuota() async throws {
        let f = try FilesFixture(stagingQuotaBytes: 150_000)
        defer { f.remove() }
        let h = try await PhoneHarness(handlers: f.files.registering())
        defer { Task { await h.shutdown() } }
        try await h.hello()
        let a = FilesFixture.bytes(100_000, seed: 1)
        let b = FilesFixture.bytes(100_000, seed: 2)
        let (_, first) = try await h.open(.filesUpload, id: 1, params: FilesFixture.uploadParams(a, name: "a.bin"))
        #expect(first["t"] == "channel.opened")
        let (_, second) = try await h.open(.filesUpload, id: 3, params: FilesFixture.uploadParams(b, name: "b.bin"))
        #expect(second["code"] == "files.too_large")
        #expect(second["details"]?["reason"] == "quota")
    }

    @Test func aReopenPreemptsAStaleChannelOfTheSameUpload() async throws {
        let f = try FilesFixture()
        defer { f.remove() }
        let h = try await PhoneHarness(handlers: f.files.registering())
        defer { Task { await h.shutdown() } }
        try await h.hello()
        let data = FilesFixture.bytes(100_000)
        let params = FilesFixture.uploadParams(data)
        let (stale, _) = try await h.open(.filesUpload, id: 1, params: params)
        try await send(data.prefix(40_000), from: 0, on: stale)
        try await stale.link.flush()
        // The old channel is still open (its session looks alive to the Mac).
        let (fresh, opened) = try await h.open(.filesUpload, id: 3, params: params)
        #expect(opened["t"] == "channel.opened")
        #expect(opened["params"]?["offset"] == .int(40_000))
        try await send(data.suffix(from: 40_000), from: 40_000, on: fresh)
        try await fresh.send(message: FilesUploadEnd(sha256: FilesFixture.sha256(data)).message)
        let done = try #require(FilesUploadDone(try message(await PhoneHarness.nextJSON(fresh))))
        #expect(try Data(contentsOf: URL(fileURLWithPath: done.path)) == data)
    }

    @Test func aReopenAfterALostDoneGetsTheSamePath() async throws {
        let f = try FilesFixture()
        defer { f.remove() }
        let h = try await PhoneHarness(handlers: f.files.registering())
        defer { Task { await h.shutdown() } }
        try await h.hello()
        let data = FilesFixture.bytes(30_000)
        let params = FilesFixture.uploadParams(data)
        let (channel, _) = try await h.open(.filesUpload, id: 1, params: params)
        try await send(data, from: 0, on: channel)
        try await channel.send(message: FilesUploadEnd(sha256: FilesFixture.sha256(data)).message)
        let done = try #require(FilesUploadDone(try message(await PhoneHarness.nextJSON(channel))))
        let (again, opened) = try await h.open(.filesUpload, id: 3, params: params)
        #expect(opened["params"]?["offset"] == .int(30_000))
        try await again.send(message: FilesUploadEnd(sha256: FilesFixture.sha256(data)).message)
        let second = try #require(FilesUploadDone(try message(await PhoneHarness.nextJSON(again))))
        #expect(second.path == done.path)
        let inbox = try FileManager.default.contentsOfDirectory(atPath: (done.path as NSString).deletingLastPathComponent)
        #expect(inbox == ["photo.jpg"])
    }

    @Test func concurrentFilesChannelsAreCappedPerDevice() async throws {
        let f = try FilesFixture(maxChannelsPerDevice: 1)
        defer { f.remove() }
        let h = try await PhoneHarness(handlers: f.files.registering())
        defer { Task { await h.shutdown() } }
        try await h.hello()
        let (_, first) = try await h.open(.filesUpload, id: 1, params: FilesFixture.uploadParams(FilesFixture.bytes(10)))
        #expect(first["t"] == "channel.opened")
        let (_, second) = try await h.open(.filesDownload, id: 3, params: ["path": "~/src/proj"])
        #expect(second["t"] == "channel.refused")
        #expect(second["retryable"] == .bool(true))
    }

    // MARK: Download

    @Test func downloadStreamsFromTheOffsetAndEndsWithFin() async throws {
        let f = try FilesFixture(chunkBytes: 16 * 1024)
        defer { f.remove() }
        let data = FilesFixture.bytes(100_000)
        try data.write(to: f.workspace.appendingPathComponent("out.log"))
        let h = try await PhoneHarness(handlers: f.files.registering())
        defer { Task { await h.shutdown() } }
        try await h.hello()
        let params = try JSONValue(encoding: FilesDownloadParams(path: "~/src/proj/out.log", offset: 40_000)).objectValue ?? [:]
        let (channel, opened) = try await h.open(.filesDownload, id: 1, params: params)
        let info = try #require(opened["params"]).decode(as: FilesDownloadOpenedParams.self)
        #expect(info.size == 100_000)
        #expect(info.sha256 == FilesFixture.sha256(data))
        #expect(info.mime == "text/plain" || info.mime == "application/octet-stream")
        var received = Data()
        var expected: UInt64 = 40_000
        while true {
            guard case .binary(let payload, let flags) = try await PhoneHarness.next(channel) else {
                Issue.record("expected a chunk")
                return
            }
            let chunk = try FileChunk(decoding: payload)
            #expect(chunk.offset == expected)
            expected += UInt64(chunk.data.count)
            received.append(chunk.data)
            if flags.contains(.fin) { break }
        }
        #expect(received == data.suffix(from: 40_000))
    }

    @Test func downloadsOfEscapesAndSpecialFilesAreRefused() async throws {
        let f = try FilesFixture()
        defer { f.remove() }
        try FileManager.default.createSymbolicLink(at: f.workspace.appendingPathComponent("leak"), withDestinationURL: f.secret)
        mkfifo(f.workspace.appendingPathComponent("pipe").path, 0o600)
        let h = try await PhoneHarness(handlers: f.files.registering())
        defer { Task { await h.shutdown() } }
        try await h.hello()
        func open(_ path: String, id: UInt32) async throws -> JSONValue {
            try await h.open(.filesDownload, id: id, params: ["path": .string(path)]).1
        }
        #expect(try await open("~/src/proj/leak", id: 1)["code"] == "files.forbidden")
        #expect(try await open(f.secret.path, id: 3)["code"] == "files.forbidden")
        #expect(try await open("~/src/proj/pipe", id: 5)["code"] == "files.not_found")
        #expect(try await open("~/src/proj/none", id: 7)["code"] == "files.not_found")
    }

    @Test func revocationStopsADownloadMidFile() async throws {
        let f = try FilesFixture(chunkBytes: 16 * 1024)
        defer { f.remove() }
        try FilesFixture.bytes(2_000_000).write(to: f.workspace.appendingPathComponent("big.bin"))
        let h = try await PhoneHarness(handlers: f.files.registering())
        defer { Task { await h.shutdown() } }
        try await h.hello()
        let (channel, _) = try await h.open(.filesDownload, id: 1, params: ["path": "~/src/proj/big.bin"], budget: 32 * 1024)
        guard case .binary = try await PhoneHarness.next(channel) else {
            Issue.record("expected a first chunk")
            return
        }
        await h.store.revoke(PhoneHarness.install)
        var bytes = 16 * 1024
        drain: while true {
            switch try await PhoneHarness.next(channel) {
            case .binary(let payload, _): bytes += payload.count - 8
            case .gap: continue
            case .json(let value):
                #expect(value["code"] == "auth.revoked")
                break drain
            case .closed: break drain
            }
        }
        #expect(bytes < 2_000_000)
    }

    // MARK: Reads

    @Test func listPagesAndReportsSymlinksWithoutFollowing() async throws {
        let f = try FilesFixture()
        defer { f.remove() }
        for name in ["b.txt", "a.txt", "c.txt"] {
            try Data(name.utf8).write(to: f.workspace.appendingPathComponent(name))
        }
        try FileManager.default.createDirectory(at: f.workspace.appendingPathComponent("dir"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: f.workspace.appendingPathComponent("link"), withDestinationURL: f.secret)
        try FileManager.default.createDirectory(at: f.workspace.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        let h = try await PhoneHarness(handlers: f.files.registering())
        defer { Task { await h.shutdown() } }
        try await h.hello()
        let (rpc, _) = try await h.open(.rpc, id: 1)
        let first = try await read(rpc, id: 1, op: "files.list", params: ["path": "~/src/proj", "limit": 3])
            .decode(as: FilesListResult.self)
        #expect(first.entries.map(\.name) == ["a.txt", "b.txt", "c.txt"])
        #expect(first.entries[0].size == 5)
        let second = try await read(rpc, id: 2, op: "files.list", params: ["path": "~/src/proj", "after": .string(first.next ?? "")])
            .decode(as: FilesListResult.self)
        #expect(second.entries.map(\.name) == ["dir", "link"])
        #expect(second.entries.map(\.kind) == [.dir, .symlink])
        #expect(second.next == nil)
        try await rpc.send(frame: .read(ReadFrame(id: 3, op: "files.list", params: ["path": "~/src/proj/link"])))
        let denied = try await PhoneHarness.nextJSON(rpc)
        #expect(denied["t"] == "error")
        #expect(denied["code"] == "files.forbidden")
        let roots = try await read(rpc, id: 4, op: "files.roots", params: .object([:])).decode(as: FilesRootsResult.self)
        #expect(roots.roots.map(\.id) == ["inbox", "ws_a1"])
    }

    // MARK: Helpers

    private func send(_ data: Data, from start: Int, on channel: MobileChannel, chunk: Int = 32 * 1024) async throws {
        var offset = start
        let bytes = Data(data)
        var index = 0
        while index < bytes.count {
            let piece = bytes[index..<min(index + chunk, bytes.count)]
            try await channel.send(binary: FileChunk(offset: UInt64(offset), data: Data(piece)).encoded)
            offset += piece.count
            index += piece.count
        }
    }

    /// The Mac may still be finishing the closed channel's writes; reopen
    /// until its staging claim is released.
    private func reopen(_ h: PhoneHarness, id: UInt32, params: [String: JSONValue], expecting offset: Int) async throws
        -> (MobileChannel, JSONValue) {
        var next = id
        while true {
            let (channel, reply) = try await h.open(.filesUpload, id: next, params: params)
            if reply["t"] == "channel.opened" {
                #expect(reply["params"]?["offset"] == .int(Int64(offset)))
                return (channel, reply)
            }
            #expect(reply["retryable"] == .bool(true))
            next += 2
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func message(_ value: JSONValue) throws -> ChannelMessage {
        guard case .message(let m) = try MobileJSON(value: value) else { throw TimeoutError() }
        return m
    }

    private func read(_ rpc: MobileChannel, id: Int, op: String, params: JSONValue) async throws -> JSONValue {
        try await rpc.send(frame: .read(ReadFrame(id: id, op: op, params: params)))
        let reply = try await PhoneHarness.nextJSON(rpc)
        #expect(reply["t"] == "read.result", "\(reply)")
        return try #require(reply["value"])
    }
}
