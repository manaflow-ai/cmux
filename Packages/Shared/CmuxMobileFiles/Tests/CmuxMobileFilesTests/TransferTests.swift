import CmuxLink
import CmuxLinkTesting
import CmuxMobileFiles
import CmuxMobileHost
import CmuxMobileLink
import CmuxMobileWire
import Foundation
import Testing

@Suite("Files client and transfer manager against a real MobileHost")
struct TransferTests {
    @Test func uploadAndDownloadRoundTripWithSha256() async throws {
        let w = try await FilesWorld()
        defer { Task { await w.shutdown() } }
        let manager = MobileTransferManager(connector: w.connector, journal: TransferJournal(fileURL: nil), chunkBytes: 16 * 1024)
        let data = FilesWorld.bytes(150_000)
        let source = try w.phoneFile("IMG_0001.jpg", data)
        let up = try await Updates.collect(await manager.start(MobileTransferRequest(
            hostID: FilesWorld.hostID, direction: .upload, localURL: source, name: "IMG_0001.jpg", mime: "image/jpeg",
            dest: FilesUploadDestination(kind: .terminal, terminal: "term_x1"))))
        let last = try #require(up.last)
        #expect(last.status == .finished)
        let uploadID = try #require(last.uploadID)
        #expect(uploadID.hasPrefix("up_"))
        #expect(await manager.records().first(where: { $0.id == last.id })?.uploadID == uploadID)
        let path = try #require(last.resultPath)
        #expect(path.hasSuffix("/Downloads/cmux-phone/IMG_0001.jpg"))
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == data)
        let running = up.filter { $0.status == .running }.map(\.completedBytes)
        #expect(running == running.sorted())

        try Data(data.reversed()).write(to: w.workspace.appendingPathComponent("build.log"))
        let local = w.phoneDirectory.appendingPathComponent("build.log")
        let down = try await Updates.collect(await manager.start(MobileTransferRequest(
            hostID: FilesWorld.hostID, direction: .download, localURL: local, remotePath: "~/src/proj/build.log", name: "build.log")))
        #expect(down.last?.status == .finished)
        #expect(try Data(contentsOf: local) == Data(data.reversed()))
        #expect(!FileManager.default.fileExists(atPath: local.path + ".cmuxpart"))
    }

    @Test func aTransportDropMidFileContinuesOnTheSameChannel() async throws {
        let w = try await FilesWorld(conditions: NetworkConditions(latency: .milliseconds(1), jitter: .milliseconds(1),
                                                                   loss: 0.2, seed: 42))
        defer { Task { await w.shutdown() } }
        let manager = MobileTransferManager(connector: w.connector, journal: TransferJournal(fileURL: nil), chunkBytes: 16 * 1024)
        let data = FilesWorld.bytes(400_000)
        let source = try w.phoneFile("clip.mov", data)
        let once = Once()
        let network = w.network
        let updates = try await Updates.collect(await manager.start(MobileTransferRequest(
            hostID: FilesWorld.hostID, direction: .upload, localURL: source, name: "clip.mov",
            dest: FilesUploadDestination(kind: .composer)))) { update in
            if update.completedBytes > 100_000, await once.fire() { await network.roam(to: .p2p) }
        }
        #expect(updates.last?.status == .finished)
        #expect(w.connects == 1, "the link resumed; no new session")
        let path = try #require(updates.last?.resultPath)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == data)
    }

    @Test func aLostSessionResumesTheUploadFromTheMacsOffset() async throws {
        let w = try await FilesWorld()
        defer { Task { await w.shutdown() } }
        let manager = MobileTransferManager(connector: w.connector, journal: TransferJournal(fileURL: nil), chunkBytes: 16 * 1024)
        let data = FilesWorld.bytes(600_000)
        let source = try w.phoneFile("big.bin", data)
        let request = MobileTransferRequest(hostID: FilesWorld.hostID, direction: .upload, localURL: source, name: "big.bin",
                                            dest: FilesUploadDestination(kind: .path, path: "~/src/proj"))
        let once = Once()
        let first = try await Updates.collect(await manager.start(request)) { update in
            if update.completedBytes > 200_000, await once.fire() { await w.killSessions() }
        }
        guard case .failed(_, _, true)? = first.last?.status else {
            Issue.record("expected a retryable failure, got \(String(describing: first.last))")
            return
        }
        let second = try await Updates.collect(try await manager.resume(request.id))
        let resumedAt = try #require(second.dropFirst().first { $0.status == .running }?.completedBytes)
        #expect(resumedAt > 0, "resumed from the Mac's partial, not from zero")
        #expect(second.last?.status == .finished)
        #expect(second.last?.resultPath?.hasSuffix("/src/proj/big.bin") == true)
        #expect(try Data(contentsOf: URL(fileURLWithPath: try #require(second.last?.resultPath))) == data)
        #expect(w.connects == 2, "a new generation on the same client")
    }

    @Test func aLostSessionResumesTheDownloadFromThePartFile() async throws {
        let w = try await FilesWorld(conditions: NetworkConditions(bytesPerSecond: 512_000), chunkBytes: 16 * 1024)
        defer { Task { await w.shutdown() } }
        let data = FilesWorld.bytes(700_000, seed: 9)
        try data.write(to: w.workspace.appendingPathComponent("dump.bin"))
        let manager = MobileTransferManager(connector: w.connector, journal: TransferJournal(fileURL: nil))
        let local = w.phoneDirectory.appendingPathComponent("dump.bin")
        let request = MobileTransferRequest(hostID: FilesWorld.hostID, direction: .download, localURL: local,
                                            remotePath: "~/src/proj/dump.bin", name: "dump.bin")
        let once = Once()
        _ = try await Updates.collect(await manager.start(request)) { update in
            if update.completedBytes > 200_000, await once.fire() { await w.killSessions() }
        }
        let second = try await Updates.collect(try await manager.resume(request.id))
        let resumedAt = try #require(second.dropFirst().first { $0.status == .running }?.completedBytes)
        #expect(resumedAt > 0)
        #expect(second.last?.status == .finished)
        #expect(try Data(contentsOf: local) == data)
    }

    @Test func aDownloadRestartsWhenTheMacFileChangedBetweenRuns() async throws {
        let w = try await FilesWorld(conditions: NetworkConditions(bytesPerSecond: 512_000), chunkBytes: 16 * 1024)
        defer { Task { await w.shutdown() } }
        let remote = w.workspace.appendingPathComponent("notes.md")
        try FilesWorld.bytes(500_000, seed: 1).write(to: remote)
        let manager = MobileTransferManager(connector: w.connector, journal: TransferJournal(fileURL: nil))
        let local = w.phoneDirectory.appendingPathComponent("notes.md")
        let request = MobileTransferRequest(hostID: FilesWorld.hostID, direction: .download, localURL: local,
                                            remotePath: "~/src/proj/notes.md", name: "notes.md")
        let once = Once()
        _ = try await Updates.collect(await manager.start(request)) { update in
            if update.completedBytes > 100_000, await once.fire() { await w.killSessions() }
        }
        let changed = FilesWorld.bytes(300_000, seed: 2)
        try changed.write(to: remote)
        let second = try await Updates.collect(try await manager.resume(request.id))
        #expect(second.last?.status == .finished)
        #expect(try Data(contentsOf: local) == changed)
    }

    @Test func aChecksumMismatchIsRefusedAndRetriedOnceThenFails() async throws {
        let w = try await FilesWorld()
        defer { Task { await w.shutdown() } }
        let data = FilesWorld.bytes(40_000)
        let source = try w.phoneFile("a.bin", data)
        let client = MobileFileClient(session: try await w.connect())
        await #expect(throws: MobileClientError.self) {
            _ = try await client.upload(source, name: "a.bin", mime: "application/octet-stream",
                                        sha256: FilesWorld.sha256(Data("not it".utf8)), dest: FilesUploadDestination(kind: .composer))
        }
        do {
            _ = try await client.upload(source, name: "a.bin", mime: "application/octet-stream",
                                        sha256: FilesWorld.sha256(Data("not it".utf8)), dest: FilesUploadDestination(kind: .composer))
        } catch let error as MobileClientError {
            #expect(error.code == "files.digest_mismatch")
        }
        // Through the manager: the journaled digest is stale (the file changed after hashing).
        let journal = TransferJournal(fileURL: nil)
        await journal.put(TransferRecord(id: "t1", hostID: FilesWorld.hostID, direction: .upload, localPath: source.path,
                                         remotePath: "", name: "a.bin", mime: "application/octet-stream",
                                         dest: FilesUploadDestination(kind: .composer), sha256: FilesWorld.sha256(Data("old".utf8)),
                                         status: .paused))
        let manager = MobileTransferManager(connector: w.connector, journal: journal)
        let updates = try await Updates.collect(try await manager.resume("t1"))
        guard case .failed("files.digest_mismatch", _, false)? = updates.last?.status else {
            Issue.record("expected digest_mismatch, got \(String(describing: updates.last))")
            return
        }
        #expect(w.connects == 1)
    }

    @Test func pathEscapesAreRefusedByTheMac() async throws {
        let w = try await FilesWorld()
        defer { Task { await w.shutdown() } }
        try FileManager.default.createSymbolicLink(at: w.workspace.appendingPathComponent("leak"),
                                                   withDestinationURL: w.home.appendingPathComponent("secret.txt"))
        let client = MobileFileClient(session: try await w.connect())
        let source = try w.phoneFile("x.sh", Data("echo".utf8))
        let sha = FilesWorld.sha256(Data("echo".utf8))
        for dest in ["~/src/proj/../..", "/tmp", "~"] {
            await expectCode("files.forbidden") {
                _ = try await client.upload(source, name: "x.sh", mime: "text/plain", sha256: sha,
                                            dest: FilesUploadDestination(kind: .path, path: dest))
            }
        }
        let part = w.phoneDirectory.appendingPathComponent("p")
        for path in ["~/src/proj/leak", "~/secret.txt", "~/src/proj/../../secret.txt"] {
            await expectCode("files.forbidden") { _ = try await client.download(path, into: part) }
        }
        await expectCode("files.forbidden") { _ = try await client.list("~") }
        let roots = try await client.roots()
        #expect(roots.map(\.id) == ["inbox", "ws_a1"])
        let listing = try await client.list("~/src/proj")
        #expect(listing.entries.map(\.name) == ["leak"])
        #expect(listing.entries.first?.kind == .symlink)
    }

    @Test func cancellationClosesTheChannelAndKeepsTheMacPartial() async throws {
        let w = try await FilesWorld(conditions: NetworkConditions(bytesPerSecond: 2_000_000))
        defer { Task { await w.shutdown() } }
        let manager = MobileTransferManager(connector: w.connector, journal: TransferJournal(fileURL: nil), chunkBytes: 16 * 1024)
        let data = FilesWorld.bytes(3_000_000)
        let source = try w.phoneFile("long.bin", data)
        let request = MobileTransferRequest(hostID: FilesWorld.hostID, direction: .upload, localURL: source, name: "long.bin",
                                            dest: FilesUploadDestination(kind: .composer))
        let once = Once()
        let updates = try await Updates.collect(await manager.start(request)) { update in
            if update.completedBytes > 64 * 1024, await once.fire() { await manager.cancel(request.id) }
        }
        #expect(updates.last?.status == .cancelled)
        #expect((updates.last?.completedBytes ?? .max) < UInt64(data.count))
        // The Mac kept what it received: a new open resumes past zero.
        let client = try await w.connect()
        let params = try JSONValue(encoding: FilesUploadParams(name: "long.bin", size: UInt64(data.count), mime: "application/octet-stream",
                                                               sha256: FilesWorld.sha256(data), dest: FilesUploadDestination(kind: .composer)))
        let opened = try await within {
            while true {
                do {
                    return try await client.open(MobileChannelRequest(kind: .filesUpload, channelClass: .bulk, window: 1 << 22,
                                                                      params: params.objectValue ?? [:], stream: "files.upload",
                                                                      priority: .bulk)).opened
                } catch MobileLinkClientError.refused(_, _, true) {
                    try await Task.sleep(for: .milliseconds(5))
                }
            }
        }
        let offset = try JSONValue.object(opened.params).decode(as: FilesUploadOpenedParams.self).offset
        #expect(offset > 0)
    }

    @Test func cancellingADownloadDeletesThePart() async throws {
        let w = try await FilesWorld(conditions: NetworkConditions(bytesPerSecond: 2_000_000), chunkBytes: 16 * 1024)
        defer { Task { await w.shutdown() } }
        try FilesWorld.bytes(3_000_000).write(to: w.workspace.appendingPathComponent("huge.bin"))
        let manager = MobileTransferManager(connector: w.connector, journal: TransferJournal(fileURL: nil))
        let local = w.phoneDirectory.appendingPathComponent("huge.bin")
        let request = MobileTransferRequest(hostID: FilesWorld.hostID, direction: .download, localURL: local,
                                            remotePath: "~/src/proj/huge.bin", name: "huge.bin")
        let once = Once()
        let updates = try await Updates.collect(await manager.start(request)) { update in
            if update.completedBytes > 64 * 1024, await once.fire() { await manager.cancel(request.id) }
        }
        #expect(updates.last?.status == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: local.path + ".cmuxpart"))
        #expect(!FileManager.default.fileExists(atPath: local.path))
    }

    private func expectCode(_ code: String, _ body: () async throws -> Void) async {
        do {
            try await body()
            Issue.record("expected \(code)")
        } catch let error as MobileClientError {
            #expect(error.code == code)
        } catch {
            Issue.record("expected \(code), got \(error)")
        }
    }
}
