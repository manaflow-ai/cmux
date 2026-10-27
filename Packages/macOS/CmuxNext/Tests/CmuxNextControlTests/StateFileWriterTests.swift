import CmuxNextCompat
import CmuxNextWakeups
import Dispatch
import Foundation
import Testing

/// A state file saved from the main actor is encoded and written on the files lane, never on the main thread
/// (plans/cmux-next/threading-model.md), the newest save wins, and the quit's `BackgroundWork.shutdown()` keeps
/// the last one.
@Suite(.timeLimit(.minutes(1))) struct StateFileWriterTests {
    /// What the writer's disk saw: each write, where it ran.
    final class Disk: Sendable {
        struct Write: Sendable, Equatable {
            var text: String?
            var onMain: Bool
        }

        // concurrency-allow: test recorder written by a lane thread and read by the test after flushed() (lock carve-out).
        private let log = Mutex<[Write]>([])
        /// Holds each write until the test lets it go (one signal per write) when set.
        let gate: DispatchSemaphore?
        /// One element as each write starts, before it waits at the gate.
        let entered: AsyncStream<Void>
        private let enter: AsyncStream<Void>.Continuation

        init(gated: Bool = false) {
            gate = gated ? DispatchSemaphore(value: 0) : nil
            (entered, enter) = AsyncStream.makeStream(of: Void.self)
        }

        var writes: [Write] { log.withLock { $0 } }

        var write: StateFileWriter.Write {
            { [self] _, data in
                enter.yield()
                gate?.blockingWait()
                log.withLock { $0.append(Write(text: data.map { String(decoding: $0, as: UTF8.self) }, onMain: Thread.isMainThread)) }
            }
        }
    }

    static func file() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "state-file-\(UUID().uuidString).json")
    }

    @Test @MainActor func aSaveFromTheMainActorIsWrittenOffTheMainThread() async {
        let disk = Disk()
        let writer = StateFileWriter(file: Self.file(), work: BackgroundWork(label: "test.state"), write: disk.write)
        writer.save { Data("one".utf8) }
        await writer.flushed()
        #expect(disk.writes == [.init(text: "one", onMain: false)])
    }

    @Test func savesWhileOneIsWrittenCollapseIntoTheNewest() async {
        let disk = Disk(gated: true)
        let writer = StateFileWriter(file: Self.file(), work: BackgroundWork(label: "test.state"), write: disk.write)
        writer.save { Data("first".utf8) }
        var entered = disk.entered.makeAsyncIterator()
        await entered.next()
        // The first write is held on the lane; these three wait behind it and only the last is written.
        writer.save { Data("second".utf8) }
        writer.save { Data("third".utf8) }
        writer.save { Data("fourth".utf8) }
        disk.gate?.signal()
        disk.gate?.signal()
        await writer.flushed()
        #expect(disk.writes.map(\.text) == ["first", "fourth"])
    }

    @Test func nilRemovesTheFileAndAThrowSkipsTheSave() async throws {
        struct Refused: Error {}
        let file = Self.file()
        defer { try? FileManager.default.removeItem(at: file) }
        let writer = StateFileWriter(file: file, work: BackgroundWork(label: "test.state"))
        writer.save { Data("kept".utf8) }
        await writer.flushed()
        #expect(try String(contentsOf: file, encoding: .utf8) == "kept")
        writer.save { throw Refused() }
        await writer.flushed()
        #expect(try String(contentsOf: file, encoding: .utf8) == "kept", "a save that cannot encode leaves the file")
        writer.save { nil }
        await writer.flushed()
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func theQuitsShutdownKeepsTheLastSave() async throws {
        let file = Self.file()
        defer { try? FileManager.default.removeItem(at: file) }
        let work = BackgroundWork(label: "test.state")
        let writer = StateFileWriter(file: file, work: work)
        writer.save { Data("typed before quit".utf8) }
        await work.shutdown()
        #expect(try String(contentsOf: file, encoding: .utf8) == "typed before quit")
        // A save after the shutdown began still runs: the lanes take blockShutdown items to the end.
        writer.save { Data("typed during quit".utf8) }
        await writer.flushed()
        #expect(try String(contentsOf: file, encoding: .utf8) == "typed during quit")
    }
}
