@testable import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Darwin
import Foundation
import os
import Testing

/// While the first window frame is still to come (the runtime's first-frame gate is closed), a launch's Chromium load
/// only reads the framework into the file cache; the map (`dlopen`, which holds dyld's loader lock and runs the
/// framework's initializers while the main thread builds the window) waits for the frame (CMUX-571). With the gate
/// open or with no gate, the load maps at once, as before.
@MainActor
@Suite struct CEFMapAfterFirstFrameTests {
    /// The read and map calls in order, each with whether it ran on the main thread; `first` gives the first one.
    nonisolated final class Steps: Sendable {
        private let calls = OSAllocatedUnfairLock<[String]>(initialState: [])
        private let stream: AsyncStream<String>
        private let continuation: AsyncStream<String>.Continuation

        init() { (stream, continuation) = AsyncStream.makeStream(of: String.self) }

        var all: [String] { calls.withLock { $0 } }

        /// The first step taken (read or map), waiting for it.
        func first() async -> String? {
            for await step in stream { return step }
            return nil
        }

        private func record(_ name: String) {
            let step = name + (pthread_main_np() != 0 ? "@main" : "")
            calls.withLock { $0.append(step) }
            continuation.yield(step)
        }

        func loader() -> CEFRuntime.LibraryLoader {
            { [self] _ in
                record("map")
                return .failure(.notEmbedded)
            }
        }

        func read() -> CEFRuntime.LibraryRead { { [self] _ in record("read") } }
    }

    private static func gate() -> FirstFrameGate {
        FirstFrameGate(backstop: DemandTimer(owner: "test", clock: ManualClock()))
    }

    @Test func aPreloadBeforeTheFirstFrameReadsThenMapsOnlyOnceTheFrameCommits() async {
        let steps = Steps()
        let runtime = CEFRuntime(libraryLoader: steps.loader(), libraryRead: steps.read())
        let gate = Self.gate()
        runtime.initializeAfter = gate
        runtime.preload(layout: CEFLibraryMapOffMainTests.layout)
        #expect(await steps.first() == "read", "the framework is read before the frame, not mapped")
        for _ in 0..<20 { await Task.yield() }
        #expect(steps.all == ["read"], "no map while the first frame is still to come")
        gate.open()
        _ = await runtime.loadTask?.value
        #expect(steps.all == ["read", "map"], "one map once the frame committed, off the main thread")
    }

    @Test func aPageThatAsksBeforeTheFirstFrameMapsOnlyOnceTheFrameCommits() async {
        let steps = Steps()
        let runtime = CEFRuntime(libraryLoader: steps.loader(), libraryRead: steps.read())
        let gate = Self.gate()
        runtime.initializeAfter = gate
        let start = Task { @MainActor in try await runtime.start(layout: CEFLibraryMapOffMainTests.layout) }
        #expect(await steps.first() == "read")
        for _ in 0..<20 { await Task.yield() }
        #expect(steps.all == ["read"])
        gate.open()
        await #expect(throws: BrowserEngineError.self) { try await start.value }
        #expect(steps.all == ["read", "map"])
    }

    @Test func afterTheFirstFrameOrWithNoGateTheLoadMapsAtOnce() async {
        let opened = Steps()
        let runtime = CEFRuntime(libraryLoader: opened.loader(), libraryRead: opened.read())
        let gate = Self.gate()
        gate.open()
        runtime.initializeAfter = gate
        runtime.preload(layout: CEFLibraryMapOffMainTests.layout)
        _ = await runtime.loadTask?.value
        #expect(opened.all == ["map"], "the frame is in: map at once, the map's own read covers the file")

        let ungated = Steps()
        let other = CEFRuntime(libraryLoader: ungated.loader(), libraryRead: ungated.read())
        other.preload(layout: CEFLibraryMapOffMainTests.layout)
        _ = await other.loadTask?.value
        #expect(ungated.all == ["map"])
    }
}
