import CmuxNextCompat
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The agent panes' small state files save off the main thread, in order, and a store made right
/// after a save reads it back (cmux#27587 follow-up: under agent disk load one such save on the
/// main thread took 1.0 s at p95).
@Suite(.serialized)
@MainActor
struct AgentPaneStateFileTests {
    static func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "state-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func aSaveRunsOffTheMainThreadAndAReadSeesIt() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = AgentPaneStateFiles()
        let file = files.at(directory.appending(path: "a.json"))
        let onMain = Mutex<Bool?>(nil)
        file.write {
            onMain.withLock { $0 = Thread.isMainThread }
            return Data("one".utf8)
        }
        #expect(file.read() == Data("one".utf8))
        #expect(onMain.withLock { $0 } == false, "the save ran on the main thread")
    }

    @Test func aBurstOfSavesEndsWithTheLast() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = AgentPaneStateFiles()
        let url = directory.appending(path: "b.json")
        let file = files.at(url)
        for value in 1...50 {
            file.write { Data("\(value)".utf8) }
        }
        // One store per file: a second one for the same path shares the queue, so it reads the last.
        #expect(files.at(url).read() == Data("50".utf8))
        // nil removes the file.
        file.write { nil }
        #expect(file.read() == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// Holds the file's queue in a first save until `release`, so the saves after it queue up.
    static func holdQueue(_ file: AgentPaneStateFile) -> DispatchSemaphore {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        file.write {
            started.signal()
            // concurrency-allow: test only; holds the file queue so later saves overlap
            // A safety net only: twice the longest wait a test makes while it holds the queue.
            _ = release.wait(timeout: .now() + 60)
            return Data("held".utf8)
        }
        // concurrency-allow: test only; the first save is running
        _ = started.wait(timeout: .now() + 10)
        return release
    }

    @Test func savesQueuedBehindARunningOneCollapseToTheNewest() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = AgentPaneStateFiles()
        let file = files.at(directory.appending(path: "o.json"))
        let release = Self.holdQueue(file)
        let encoded = Mutex<[Int]>([])
        for value in 1...20 {
            file.write {
                encoded.withLock { $0.append(value) }
                return Data("\(value)".utf8)
            }
        }
        release.signal()
        #expect(file.read() == Data("20".utf8))
        #expect(encoded.withLock { $0 } == [20], "replaced saves still encoded")
    }

    @Test func aThrowingEncodeKeepsTheLastGoodFile() throws {
        struct Failed: Error {}
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = AgentPaneStateFiles()
        let file = files.at(directory.appending(path: "t.json"))
        file.write { Data("good".utf8) }
        #expect(file.read() == Data("good".utf8))
        file.write { throw Failed() }
        #expect(file.read() == Data("good".utf8))
    }

    @Test func aReadFromInsideASaveDoesNotWaitOnItself() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = AgentPaneStateFiles()
        let file = files.at(directory.appending(path: "r.json"))
        file.write { Data("first".utf8) }
        #expect(file.read() == Data("first".utf8))
        let inner = Mutex<Data?>(nil)
        file.write {
            inner.withLock { $0 = file.read() }
            return Data("second".utf8)
        }
        #expect(file.read() == Data("second".utf8))
        #expect(inner.withLock { $0 } == Data("first".utf8))
    }

    @Test func aReadOfAnotherFileFromInsideASaveWaitsForThatFilesSaves() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = AgentPaneStateFiles()
        let a = files.at(directory.appending(path: "a2.json"))
        let b = files.at(directory.appending(path: "b2.json"))
        let release = Self.holdQueue(b)
        b.write { Data("b".utf8) }
        let seen = Mutex<Data?>(nil)
        let reading = DispatchSemaphore(value: 0)
        let read = DispatchSemaphore(value: 0)
        a.write {
            reading.signal()
            seen.withLock { $0 = b.read() }
            read.signal()
            return Data("a".utf8)
        }
        // concurrency-allow: test only; A's save has reached its read of B
        #expect(reading.wait(timeout: .now() + 30) == .success, "A's save never reached its read of B")
        // concurrency-allow: test only; while B is held the read must not finish (it did, at once, with one key on every queue)
        #expect(read.wait(timeout: .now() + 0.3) == .timedOut, "read B while its queue was still busy")
        release.signal()
        #expect(a.read() == Data("a".utf8))
        #expect(seen.withLock { $0 } == Data("b".utf8), "read b directly instead of after its queued save")
    }

    /// A file with a save queued or running is named as saving (the quit deadline records those, by
    /// name only); once its saves ran it is not.
    @Test func aFileIsSavingUntilItsQueuedSavesRan() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = AgentPaneStateFiles()
        let url = directory.appending(path: "d.json")
        let release = Self.holdQueue(files.at(url))
        files.at(url).write { Data("late".utf8) }
        _ = files.at(directory.appending(path: "idle.json"))
        #expect(files.savingFileNames() == ["d.json"])
        release.signal()
        await files.drained()
        #expect(files.savingFileNames().isEmpty)
        #expect((try? Data(contentsOf: url)) == Data("late".utf8))
    }

    @Test func drainedWaitsForQueuedSaves() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = AgentPaneStateFiles()
        let url = directory.appending(path: "c.json")
        files.at(url).write { Data("quit".utf8) }
        await files.drained()
        #expect((try? Data(contentsOf: url)) == Data("quit".utf8))
    }

    /// The quit awaits the saves after its deadline is armed: the wait holds no thread (the main actor
    /// lets the held save go once the drain began; a wait that blocked it would never end, and the time
    /// limit fails the test), and it ends once the saves queued before it ran.
    @Test(.timeLimit(.minutes(1)))
    func drainedAwaitsQueuedSavesWithoutBlocking() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let began = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let files = AgentPaneStateFiles(drainBegan: { began.continuation.yield() })
        let url = directory.appending(path: "e.json")
        let release = Self.holdQueue(files.at(url))
        files.at(url).write { Data("forced".utf8) }
        let drained = Task { await files.drained() }
        for await _ in began.stream { break }
        release.signal()
        await drained.value
        #expect((try? Data(contentsOf: url)) == Data("forced".utf8))
    }

    @Test func unsentDraftsAndScrollPlacesSurviveAFreshStore() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = AgentPaneStateFiles()
        let drafts = AgentUnsentDrafts(directory: directory, files: files)
        drafts.set("first", for: "tab-1")
        drafts.set("second", for: "tab-1")
        let relaunched = AgentUnsentDrafts(directory: directory, files: files)
        #expect(relaunched.hasDraft("tab-1"))
        let anchors = AgentPaneScrollAnchors(directory: directory, files: files)
        anchors.remember(AgentPaneScrollAnchor(rowId: "row-3", offset: 4), for: "s-1")
        #expect(AgentPaneScrollAnchors(directory: directory, files: files).anchor(for: "s-1") == AgentPaneScrollAnchor(rowId: "row-3", offset: 4))
    }
}
