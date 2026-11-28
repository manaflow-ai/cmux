import CryptoKit
import Foundation
import Testing
@testable import CmuxUpdater

@Suite struct CASArchiveAssemblerTests {
    private static func sha(_ data: Data) -> String {
        CASArchiveAssembler.hex(SHA256.hash(data: data))
    }

    private static func manifestJSON(_ pieces: [Data], format: String = CASArchiveAssembler.manifestFormat) -> Data {
        let whole = pieces.reduce(Data(), +)
        let chunks = pieces.map { "{\"sha256\":\"\(sha($0))\",\"size\":\($0.count)}" }.joined(separator: ",")
        return Data("{\"format\":\"\(format)\",\"size\":\(whole.count),\"sha256\":\"\(sha(whole))\",\"chunks\":[\(chunks)]}".utf8)
    }

    private static func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cas-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private final class Remote: @unchecked Sendable {
        let lock = NSLock()
        var chunks: [String: Data] = [:]
        var fetched: [String] = []
        func fetch(_ sha: String) throws -> Data {
            lock.lock(); defer { lock.unlock() }
            fetched.append(sha)
            guard let data = chunks[sha] else { throw URLError(.fileDoesNotExist) }
            return data
        }
    }

    @Test func offByDefault() {
        let defaults = UserDefaults(suiteName: "cas-\(UUID().uuidString)")!
        #expect(CASArchiveAssembler.isEnabled(in: defaults) == false)
        defaults.set(true, forKey: CASArchiveAssembler.enabledKey)
        #expect(CASArchiveAssembler.isEnabled(in: defaults))
    }

    @Test func assemblesBitExactAndFetchesOnlyMissingChunks() async throws {
        let pieces = (0..<4).map { Data(repeating: UInt8($0 + 1), count: 1000 + $0) }
        let remote = Remote()
        for p in pieces { remote.chunks[Self.sha(p)] = p }
        let dir = try Self.tempDir()
        let assembler = CASArchiveAssembler(store: dir.appendingPathComponent("store")) { try remote.fetch($0) }
        try assembler.put(Self.sha(pieces[0]), pieces[0])
        try assembler.put(Self.sha(pieces[2]), pieces[2])

        let manifest = try CASArchiveAssembler.decodeManifest(Self.manifestJSON(pieces))
        #expect(assembler.missingBytes(for: manifest) == pieces[1].count + pieces[3].count)
        let out = dir.appendingPathComponent("update.dmg")
        try await assembler.assemble(manifest, to: out)

        #expect(try Data(contentsOf: out) == pieces.reduce(Data(), +))
        #expect(remote.fetched == [Self.sha(pieces[1]), Self.sha(pieces[3])])
        #expect(assembler.missingBytes(for: manifest) == 0)
    }

    @Test func rejectsTamperedChunkAndLeavesNoFile() async throws {
        let pieces = [Data(repeating: 7, count: 500), Data(repeating: 9, count: 600)]
        let remote = Remote()
        remote.chunks[Self.sha(pieces[0])] = pieces[0]
        remote.chunks[Self.sha(pieces[1])] = Data(repeating: 8, count: 600)
        let dir = try Self.tempDir()
        let assembler = CASArchiveAssembler(store: dir.appendingPathComponent("store")) { try remote.fetch($0) }
        let manifest = try CASArchiveAssembler.decodeManifest(Self.manifestJSON(pieces))
        let out = dir.appendingPathComponent("update.dmg")

        await #expect(throws: CASArchiveAssembler.Failure.chunkDigestMismatch(Self.sha(pieces[1]))) {
            try await assembler.assemble(manifest, to: out)
        }
        #expect(FileManager.default.fileExists(atPath: out.path) == false)
        #expect(assembler.hasChunk(Self.sha(pieces[1])) == false)
    }

    @Test func rejectsUnknownFormatAndBadSizes() throws {
        let pieces = [Data(repeating: 1, count: 10)]
        #expect(throws: CASArchiveAssembler.Failure.unsupportedFormat("cmux-cas-manifest/9")) {
            try CASArchiveAssembler.decodeManifest(Self.manifestJSON(pieces, format: "cmux-cas-manifest/9"))
        }
        let bad = Data("{\"format\":\"cmux-cas-manifest/0\",\"size\":11,\"sha256\":\"00\",\"chunks\":[{\"sha256\":\"\(Self.sha(pieces[0]))\",\"size\":10}]}".utf8)
        #expect(throws: CASArchiveAssembler.Failure.sizeMismatch) {
            try CASArchiveAssembler.decodeManifest(bad)
        }
    }

    @Test func readsThePythonPublisherFormat() throws {
        // The shape scripts/cas/mac_archive_manifest.py writes, including keys the assembler ignores.
        let json = Data("""
        {"format":"cmux-cas-manifest/0","chunker":{"kind":"fastcdc-gear-sha256","min":16384,"avg":65536,"max":262144},
         "name":"n.dmg","size":3,"sha256":"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
         "chunks":[{"sha256":"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad","size":3,"z":11}]}
        """.utf8)
        let manifest = try CASArchiveAssembler.decodeManifest(json)
        #expect(manifest.chunks.count == 1)
        #expect(manifest.size == 3)
    }
}
