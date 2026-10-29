@testable import CmuxNextBrowser
import CmuxNextWakeups
import Foundation
import os
import Testing

/// A predicted Chromium start's framework read (``CEFFrameworkPrefetch``) is one idle lane item
/// that the startup best-effort fence holds, so a cold launch with no visible Chromium page reads no Chromium file
/// before startup completes; a start someone waits for promotes it to a user-blocking read that the fence never
/// holds. Against a scratch framework folder and a spy in-process load.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct CEFFrameworkPrefetchTests {
    @Test func aFencedPrefetchReadsNoFileUntilTheFenceEnds() async throws {
        let framework = try ScratchFramework()
        let lanes = Lanes()
        lanes.work.beginBestEffortFence()
        let prefetch = CEFFrameworkPrefetch()

        prefetch.post(framework.layout, on: lanes.work)
        await lanes.queued.wait()
        // The files lane still runs work the fence does not hold, while the read waits.
        try await Task(priority: .high) { try await lanes.work.run(.userBlocking, mayBlock: .files) {} }.value
        #expect(prefetch.last == nil, "a Chromium file was read behind the fence")

        lanes.work.endBestEffortFence()
        #expect(await prefetch.finished(), "a read that ran told the load not to map")
        await lanes.idleRan.wait()
        #expect(prefetch.last?.files == framework.fileCount)
        #expect(prefetch.last?.bytes == framework.byteCount)
    }

    @Test func aPromotionReadsEverythingAtUserBlockingWhileTheFenceStaysUp() async throws {
        let framework = try ScratchFramework()
        let lanes = Lanes()
        lanes.work.beginBestEffortFence()
        let prefetch = CEFFrameworkPrefetch()
        prefetch.post(framework.layout, on: lanes.work)
        await lanes.queued.wait()

        await prefetch.promote(on: lanes.work)
        await lanes.blockingRan.wait()

        #expect(prefetch.last?.files == framework.fileCount)
        #expect(prefetch.last?.bytes == framework.byteCount)
        #expect(lanes.priorities == [.userBlocking], "the promoted read did not run at user-blocking")
        // Every waiter goes on although the idle item is still held.
        #expect(await prefetch.finished())

        // The held item runs after the fence and reads nothing again.
        lanes.work.endBestEffortFence()
        await lanes.idleRan.wait()
        #expect(prefetch.last?.bytes == framework.byteCount, "a file was read twice")
    }

    @Test func aPromotionWithNoQueuedReadDoesNothing() async throws {
        let lanes = Lanes()
        let prefetch = CEFFrameworkPrefetch()
        await prefetch.promote(on: lanes.work)
        #expect(prefetch.last == nil)
        #expect(lanes.priorities.isEmpty)
    }

    /// The load's own read before the map and its warm read go through the same prefetch, so after the fenced
    /// read they read no byte again (a fresh prefetch per load would read the 367 MiB framework twice).
    @Test func theLoadsOwnReadsSkipWhatTheFencedReadRead() async throws {
        let framework = try ScratchFramework()
        let lanes = Lanes()
        let prefetch = CEFFrameworkPrefetch()
        prefetch.post(framework.layout, on: lanes.work)
        #expect(await prefetch.finished())

        prefetch.readBinary(framework.layout)
        prefetch.warm(framework.layout)

        #expect(prefetch.last?.bytes == framework.byteCount, "the load read a file the fenced read had read")
        #expect(prefetch.last?.files == framework.fileCount)
    }

    @Test func aPreloadMapsOnlyAfterTheFencedReadEnds() async throws {
        let framework = try ScratchFramework()
        let lanes = Lanes()
        lanes.work.beginBestEffortFence()
        let loads = LoadSpy(result: .success(try MappedLibrary.make(framework.layout)))
        let runtime = Self.runtime(lanes: lanes, loads: loads)

        runtime.preload(layout: framework.layout)
        await lanes.queued.wait()
        #expect(loads.count == 0, "the preload mapped the framework behind the fence")
        #expect(runtime.prefetch.last == nil)
        #expect(runtime.report.state == "loading")

        lanes.work.endBestEffortFence()
        await runtime.libraryLoadEnded()
        #expect(loads.count == 1)
        #expect(runtime.prefetch.last?.bytes == framework.byteCount)
        #expect(await Self.settledState(runtime) == "loaded", "a mapped fenced preload did not report itself loaded")
        // The map is a plain task like the unfenced preload's, never a lane item: only the read's idle items ran.
        #expect(lanes.priorities.allSatisfy { $0 == .idle })
    }

    @Test func aTabStartPromotesThePreloadsFencedReadAndMapsAtItsPriority() async throws {
        let framework = try ScratchFramework()
        let lanes = Lanes()
        lanes.work.beginBestEffortFence()
        let loads = LoadSpy()
        let runtime = Self.runtime(lanes: lanes, loads: loads)
        runtime.preload(layout: framework.layout)
        await lanes.queued.wait()

        // The spy load fails, so the start throws; it got that far with the fence still up.
        await #expect(throws: BrowserEngineError.self) {
            try await runtime.start(layout: framework.layout, environment: [:], trigger: "tab")
        }

        await lanes.blockingRan.wait()
        await runtime.libraryLoadEnded()
        #expect(loads.count == 1, "the preload and the start both mapped")
        #expect(runtime.prefetch.last?.files == framework.fileCount)
        #expect(runtime.prefetch.last?.bytes == framework.byteCount)
        #expect(lanes.priorities.contains(.userBlocking))
        #expect(!lanes.priorities.contains(.idle), "the fenced idle read ran before the fence ended")
        #expect(!lanes.priorities.contains(.bestEffort), "the map waited on a best-effort lane slot")
        #expect(loads.priorities.allSatisfy { $0 >= .userInitiated }, "the promoted map ran at \(loads.priorities)")
        lanes.work.endBestEffortFence()
    }

    @Test func aReadDroppedAtQuitMapsNothing() async throws {
        let framework = try ScratchFramework()
        let lanes = Lanes()
        lanes.work.beginBestEffortFence()
        let loads = LoadSpy()
        let runtime = Self.runtime(lanes: lanes, loads: loads)
        runtime.preload(layout: framework.layout)
        await lanes.queued.wait()

        lanes.work.beginShutdown()
        await runtime.libraryLoadEnded()
        // A start after the drop maps nothing either.
        await #expect(throws: BrowserEngineError.self) {
            try await runtime.start(layout: framework.layout, environment: [:], trigger: "tab")
        }

        #expect(loads.count == 0, "the quit mapped the framework")
        #expect(runtime.prefetch.last == nil)
    }

    @Test func withoutLanesAPreloadMapsAtOnce() async throws {
        let framework = try ScratchFramework()
        let loads = LoadSpy()
        let runtime = CEFRuntime(storage: CEFProfileStorage(root: ScratchFramework.scratch()))
        runtime.loadInProcess = { _ in loads.load() }

        runtime.preload(layout: framework.layout)
        await runtime.libraryLoadEnded()

        #expect(runtime.fencedRead == nil)
        #expect(loads.count == 1)
    }

    /// The report once the preload's main-actor follow-up, which sets `loaded` after the map ended, had its turns.
    private static func settledState(_ runtime: CEFRuntime) async -> String {
        var turns = 0
        while runtime.report.state != "loaded", turns < 1000 {
            turns += 1
            await Task.yield()
        }
        return runtime.report.state
    }

    /// A runtime whose predicted start reads through `lanes` and whose in-process load only counts its calls.
    private static func runtime(lanes: Lanes, loads: LoadSpy) -> CEFRuntime {
        let runtime = CEFRuntime(storage: CEFProfileStorage(root: ScratchFramework.scratch()))
        runtime.prefetchWork = lanes.work
        runtime.loadInProcess = { _ in loads.load() }
        return runtime
    }
}

/// A framework folder with a binary, two top-level resources and a locale folder the read leaves out.
nonisolated private struct ScratchFramework {
    let layout: CEFRuntimeLayout
    let fileCount = 3
    let byteCount = 3 * (1 << 20) + (1 << 20) + 10

    init() throws {
        let root = Self.scratch()
        layout = CEFRuntimeLayout(frameworksDirectory: root, mainBundle: root.appending(path: "cmux.app"),
                                  helperApp: root.appending(path: "cmux Helper.app"))
        let resources = layout.frameworkDirectory.appending(path: "Resources")
        try FileManager.default.createDirectory(at: resources.appending(path: "en.lproj"), withIntermediateDirectories: true)
        try Data(count: 3 * (1 << 20)).write(to: layout.frameworkBinary)
        try Data(count: 1 << 20).write(to: resources.appending(path: "resources.pak"))
        try Data(count: 10).write(to: resources.appending(path: "icudtl.dat"))
        try Data(count: 99).write(to: resources.appending(path: "en.lproj/locale.pak"))
    }

    static func scratch() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "cef-prefetch-\(UUID().uuidString)", directoryHint: .isDirectory)
    }
}

/// Lanes that report each queued item and each run's priority.
nonisolated private final class Lanes: Sendable {
    /// An item had to wait (the fence held it).
    let queued: Signals
    /// An idle item ran (and reported its run).
    let idleRan: Signals
    /// A user-blocking item ran (and reported its run).
    let blockingRan: Signals
    private let runs: OSAllocatedUnfairLock<[WorkPriority]>
    let work: BackgroundWork

    init() {
        let queued = Signals(), idleRan = Signals(), blockingRan = Signals()
        let runs = OSAllocatedUnfairLock<[WorkPriority]>(initialState: [])
        self.queued = queued
        self.idleRan = idleRan
        self.blockingRan = blockingRan
        self.runs = runs
        // onRan comes after the item's body, so after an awaiting caller may have resumed: tests wait for the signals.
        work = BackgroundWork(cpuWidth: 2, label: "test.cefprefetch", onQueued: { _, _ in queued.signal() },
                              onRan: { _, priority, _, _ in
                                  runs.withLock { $0.append(priority) }
                                  if priority == .idle { idleRan.signal() }
                                  if priority == .userBlocking { blockingRan.signal() }
                              })
    }

    /// The priorities of the items that ran, in order.
    var priorities: [WorkPriority] { runs.withLock { $0 } }
}

/// Lane bodies (synchronous) signal; the async test awaits the signals.
nonisolated private struct Signals: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() { (stream, continuation) = AsyncStream.makeStream(of: Void.self) }

    func signal() { continuation.yield() }

    func wait() async {
        for await _ in stream { return }
    }
}

/// Counts in-process loads and the task priority each ran at; each returns `result` (by default it fails as a
/// runtime that is not embedded).
nonisolated private final class LoadSpy: Sendable {
    private let loads = OSAllocatedUnfairLock<[TaskPriority]>(initialState: [])
    private let result: Result<CEFLoadedLibrary, CEFRuntime.BootError>

    init(result: Result<CEFLoadedLibrary, CEFRuntime.BootError> = .failure(.notEmbedded)) { self.result = result }

    var count: Int { loads.withLock { $0.count } }

    /// The priority of each load, in order.
    var priorities: [TaskPriority] { loads.withLock { $0 } }

    func load() -> Result<CEFLoadedLibrary, CEFRuntime.BootError> {
        let priority = Task.currentPriority
        loads.withLock { $0.append(priority) }
        return result
    }
}

/// A mapped library over a shim whose every function does nothing and returns 0.
nonisolated private enum MappedLibrary {
    static func make(_ layout: CEFRuntimeLayout) throws -> CEFLoadedLibrary {
        let nothing: @convention(c) () -> Int = { 0 }
        let shim = try CEFShimLibrary.resolving { _ in unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self) }
        return CEFLoadedLibrary(shim: shim, shimABI: "", layout: layout,
                                locale: CEFLocale(locale: CEFLocale.fallback, acceptLanguages: CEFLocale.fallback), loadDuration: .zero)
    }
}
