import Foundation
import Testing

@testable import CmuxFileSearch

/// A backend the test drives by hand: each search waits until the test
/// completes it, and cancellation is recorded.
final class ScriptedBackend: FileSearchBackend, @unchecked Sendable {
    final class Run: @unchecked Sendable {
        let query: FileSearchQuery
        let sink: FileSearchBatchMailbox
        var continuation: CheckedContinuation<FileSearchCompletion, Never>?
        var wasCancelled = false

        init(query: FileSearchQuery, sink: FileSearchBatchMailbox) {
            self.query = query
            self.sink = sink
        }
    }

    private let lock = NSLock()
    private var runs: [Run] = []
    private let started = AsyncStream<Int>.makeStream()

    func search(query: FileSearchQuery, rootPath: String, matchLimit: Int, sink: FileSearchBatchMailbox) async -> FileSearchCompletion {
        let run = Run(query: query, sink: sink)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                run.continuation = continuation
                runs.append(run)
                let count = runs.count
                let cancelled = run.wasCancelled
                lock.unlock()
                started.continuation.yield(count)
                if cancelled { resume(run, with: .completed) }
            }
        } onCancel: {
            lock.lock()
            run.wasCancelled = true
            lock.unlock()
            resume(run, with: .completed)
        }
    }

    private func resume(_ run: Run, with completion: FileSearchCompletion) {
        lock.lock()
        let continuation = run.continuation
        run.continuation = nil
        lock.unlock()
        continuation?.resume(returning: completion)
    }

    func run(_ index: Int) -> Run {
        lock.lock()
        defer { lock.unlock() }
        return runs[index]
    }

    var runCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return runs.count
    }

    func complete(_ index: Int, with completion: FileSearchCompletion) {
        resume(run(index), with: completion)
    }

    func waitForRuns(_ count: Int) async {
        if runCount >= count { return }
        for await value in started.stream where value >= count { return }
    }
}

@MainActor
private final class EventRecorder {
    var events: [FileSearchEngineEvent] = []
    private let stream = AsyncStream<FileSearchEngineEvent>.makeStream()

    func attach(to engine: FileSearchEngine) {
        engine.onEvent = { [weak self] event in
            self?.events.append(event)
            self?.stream.continuation.yield(event)
        }
    }

    /// Waits for the first event after the current point that satisfies `predicate`.
    func wait(for predicate: (FileSearchEngineEvent) -> Bool) async {
        for await event in stream.stream where predicate(event) { return }
    }
}

private func group(_ path: String, lines: [Int]) -> FileSearchFileMatches {
    FileSearchFileMatches(
        path: path,
        matches: lines.map { FileSearchMatch(lineNumber: $0, column: 1, length: 1, preview: "x", previewMatchRange: 0..<1) }
    )
}

@MainActor
@Suite("Search engine lifecycle", .serialized)
struct FileSearchEngineTests {
    private func request(_ pattern: String, backend: ScriptedBackend, revision: Int = 0, isRegex: Bool = false) -> FileSearchRequest {
        FileSearchRequest(
            query: FileSearchQuery(pattern: pattern, isRegex: isRegex),
            rootPath: "/root",
            scopeIdentity: "local",
            contentRevision: revision,
            backend: backend
        )
    }

    private func makeEngine(clock: ManualTestClock, frame: Duration = .zero) -> FileSearchEngine {
        FileSearchEngine(clock: clock, debounceInterval: .milliseconds(200), frameInterval: frame, matchLimit: 1_000) {
            String($0.dropFirst("/root/".count))
        }
    }

    @Test("A burst of scheduled queries runs only the last one, after the debounce")
    func debounce() async {
        let clock = ManualTestClock()
        let backend = ScriptedBackend()
        let engine = makeEngine(clock: clock)

        for pattern in ["p", "pr", "pri", "priv"] {
            engine.schedule(request(pattern, backend: backend))
        }
        await clock.waitForSleepers(1)
        #expect(backend.runCount == 0)

        clock.advance(by: .milliseconds(199))
        #expect(backend.runCount == 0)
        clock.advance(by: .milliseconds(1))
        await backend.waitForRuns(1)

        #expect(backend.runCount == 1)
        #expect(backend.run(0).query.pattern == "priv")
        engine.cancel(clearResults: true)
    }

    @Test("A new query cancels the running one and its late output is discarded")
    func supersededSearchIsCancelled() async {
        let clock = ManualTestClock()
        let backend = ScriptedBackend()
        let engine = makeEngine(clock: clock)
        let recorder = EventRecorder()
        recorder.attach(to: engine)

        engine.start(request("old", backend: backend))
        await backend.waitForRuns(1)
        engine.start(request("new", backend: backend))
        await backend.waitForRuns(2)

        #expect(backend.run(0).wasCancelled)
        backend.run(0).sink.send([group("/root/stale", lines: [1])])
        backend.run(1).sink.send([group("/root/fresh", lines: [1, 2])])
        backend.complete(1, with: .completed)
        await recorder.wait { $0 == .phase(.finished(.completed)) }

        #expect(engine.tree.files.map(\.relativePath) == ["fresh"])
        #expect(engine.tree.matchCount == 2)
        #expect(engine.activeRequest?.query.pattern == "new")
    }

    @Test("An identical request while searching does not restart; a new content revision does")
    func duplicateRequests() async {
        let clock = ManualTestClock()
        let backend = ScriptedBackend()
        let engine = makeEngine(clock: clock)

        engine.start(request("same", backend: backend))
        await backend.waitForRuns(1)
        engine.start(request("same", backend: backend))
        #expect(backend.runCount == 1)
        #expect(!backend.run(0).wasCancelled)

        engine.start(request("same", backend: backend, revision: 1))
        await backend.waitForRuns(2)
        #expect(backend.run(0).wasCancelled)
        engine.cancel(clearResults: true)
    }

    @Test("Batches arriving within one frame are applied as one update")
    func framePacing() async {
        let clock = ManualTestClock()
        let backend = ScriptedBackend()
        let engine = makeEngine(clock: clock, frame: .milliseconds(16))
        let recorder = EventRecorder()
        recorder.attach(to: engine)

        engine.start(request("x", backend: backend))
        await backend.waitForRuns(1)
        let run = backend.run(0)

        run.sink.send([group("/root/a", lines: [1])])
        await recorder.wait { if case .changed = $0 { true } else { false } }
        await clock.waitForSleepers(1)

        run.sink.send([group("/root/a", lines: [2])])
        run.sink.send([group("/root/b", lines: [1])])
        run.sink.send([group("/root/c", lines: [1])])
        #expect(engine.tree.matchCount == 1)

        clock.advance(by: .milliseconds(16))
        await recorder.wait { if case .changed = $0 { true } else { false } }

        let changes = recorder.events.compactMap { event -> FileSearchTreeChange? in
            if case .changed(let change) = event { change } else { nil }
        }
        #expect(changes.count == 2)
        #expect(changes[1].grownFiles.map(\.fileIndex) == [0])
        #expect(changes[1].insertedFiles == 1..<3)
        #expect(engine.tree.matchCount == 4)
        engine.cancel(clearResults: true)
    }

    @Test("A limited search reports the limit")
    func limited() async {
        let clock = ManualTestClock()
        let backend = ScriptedBackend()
        let engine = makeEngine(clock: clock)
        let recorder = EventRecorder()
        recorder.attach(to: engine)

        engine.start(request("x", backend: backend))
        await backend.waitForRuns(1)
        backend.complete(0, with: .limited(1_000))
        await recorder.wait { if case .phase(.finished) = $0 { true } else { false } }

        #expect(engine.phase == .finished(.limited(1_000)))
    }

    @Test("Empty and invalid-regex queries never reach the backend")
    func queriesThatDoNotRun() {
        let clock = ManualTestClock()
        let backend = ScriptedBackend()
        let engine = makeEngine(clock: clock)

        engine.start(request("", backend: backend))
        #expect(engine.phase == .idle)

        engine.start(request("(", backend: backend, isRegex: true))
        #expect(engine.phase == .finished(.failed(.invalidRegex(nil))))
        #expect(backend.runCount == 0)
    }

    @Test("Cancel with clear stops the backend and empties the results")
    func cancelClears() async {
        let clock = ManualTestClock()
        let backend = ScriptedBackend()
        let engine = makeEngine(clock: clock)

        engine.start(request("x", backend: backend))
        await backend.waitForRuns(1)
        engine.cancel(clearResults: true)

        #expect(backend.run(0).wasCancelled)
        #expect(engine.phase == .idle)
        #expect(engine.tree.isEmpty)
        #expect(engine.activeRequest == nil)
    }
}
