import CmuxNextWakeups
import Foundation
import Testing

/// OrderedWrites: saves land in call order on the files lane, flush waits for them, and an error reaches `failed`.
@Suite(.timeLimit(.minutes(1))) struct OrderedWritesTests {
    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "ordered-writes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func savesLandInCallOrderAndFlushWaitsForThem() async throws {
        let file = try Self.folder().appending(path: "sub/state.json")
        let writes = OrderedWrites(work: BackgroundWork(label: "test.writes")) { Issue.record("write failed: \($0)") }
        for index in 0..<200 { writes.save(Data("\(index)".utf8), to: file) }
        await writes.flush()
        #expect(try String(contentsOf: file, encoding: .utf8) == "199")
        writes.save(nil, to: file)
        await writes.flush()
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aFailedSaveReachesItsHandlerAndLaterSavesStillLand() async throws {
        let folder = try Self.folder()
        let (errors, report) = AsyncStream.makeStream(of: String.self)
        let writes = OrderedWrites(work: BackgroundWork(label: "test.writes.fail")) { report.yield(String(describing: $0)) }
        writes.enqueue { throw CocoaError(.fileWriteNoPermission) }
        writes.save(Data("ok".utf8), to: folder.appending(path: "after.json"))
        await writes.flush()
        var iterator = errors.makeAsyncIterator()
        #expect(await iterator.next() != nil)
        #expect(try String(contentsOf: folder.appending(path: "after.json"), encoding: .utf8) == "ok")
    }

    @Test func shutdownWaitsForQueuedSaves() async throws {
        let file = try Self.folder().appending(path: "quit.json")
        let work = BackgroundWork(label: "test.writes.quit")
        let writes = OrderedWrites(work: work) { Issue.record("write failed: \($0)") }
        for index in 0..<50 { writes.save(Data("\(index)".utf8), to: file) }
        await work.shutdown()
        #expect(try String(contentsOf: file, encoding: .utf8) == "49")
    }
}
