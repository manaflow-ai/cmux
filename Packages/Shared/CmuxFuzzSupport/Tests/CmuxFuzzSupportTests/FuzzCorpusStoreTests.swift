@testable import CmuxFuzzSupport
import Foundation
import Testing

/// The stored corpus layout of scripts/cmux-next/fuzz-corpus.py and the 64 KiB limit of checked-in
/// regression inputs (p10-stability-183).
@Suite struct FuzzCorpusStoreTests {
    @Test func aRunStartsFromTheStoredInputsAndReportsTheirCount() throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FuzzCorpusStore(root: root)
        let folder = store.inputs(for: "Suite.case")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("stored".utf8).write(to: folder.appendingPathComponent("b1"))
        try Data("xy".utf8).write(to: folder.appendingPathComponent("a0"))
        #expect(folder.path == root.appendingPathComponent("inputs/Suite.case").path)

        let run = FuzzRun("Suite.case", seed: 1, iterations: 0, environment: store.environment(FuzzEnvironment()))
        let corpus = try run.corpus(seeds: [Data("s".utf8)])
        #expect(corpus.inputs == ["s", "xy", "stored"].map { Data($0.utf8) })
        #expect(corpus.byteCount == 9)
        #expect(corpus.startLine(name: run.name) == "Suite.case: starts from 3 inputs (9 bytes)")
    }

    @Test func theSummaryComesFromTheMetaFileAndABadOneIsAnError() throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FuzzCorpusStore(root: root)
        #expect(try store.summary(for: "t") == nil)
        let meta = root.appendingPathComponent("meta", isDirectory: true)
        try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
        let written = #"{"target": "t", "generation": 4, "count": 2, "bytes": 9, "run": "r", "updated": "now"}"#
        try Data(written.utf8).write(to: meta.appendingPathComponent("t.json"))
        #expect(try store.summary(for: "t") == FuzzCorpusStore.Summary(generation: 4, count: 2, bytes: 9))

        try Data("{".utf8).write(to: meta.appendingPathComponent("bad.json"))
        #expect(throws: FuzzError.self) { try store.summary(for: "bad") }
    }

    @Test func regressionsLoadInNameOrderAndRefuseAnInputOver64KiB() throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try FuzzCorpus.regressions(name: "Decoder.frame", in: root).isEmpty)
        let folder = root.appendingPathComponent("Decoder.frame", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("2".utf8).write(to: folder.appendingPathComponent("regress-b"))
        try Data("1".utf8).write(to: folder.appendingPathComponent("regress-a"))
        try Data("hidden".utf8).write(to: folder.appendingPathComponent(".skip"))
        let limit = FuzzCorpusStore.maxCheckedInInputBytes
        try Data(count: limit).write(to: folder.appendingPathComponent("regress-c"))
        let loaded = try FuzzCorpus.regressions(name: "Decoder.frame", in: root)
        #expect(loaded.map(\.count) == [1, 1, limit])

        try Data(count: limit + 1).write(to: folder.appendingPathComponent("regress-d"))
        do {
            _ = try FuzzCorpus.regressions(name: "Decoder.frame", in: root)
            Issue.record("an input over the limit loaded")
        } catch let FuzzError.corpusInputTooLarge(path, bytes) {
            #expect(path.hasSuffix("/Decoder.frame/regress-d"))
            #expect(bytes == limit + 1)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fuzz-corpus-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
