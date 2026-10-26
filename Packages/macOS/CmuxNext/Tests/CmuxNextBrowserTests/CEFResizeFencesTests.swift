import AppKit
@testable import CmuxNextBrowser
import Darwin
import Testing

/// Fork-seam tests of p03-rendering-043: one Core Animation fence per geometry transaction that
/// resizes Chromium pages, given to every resized page with a 2-frame deadline, held once by each
/// window context, and released by the app after the commit on every path (a browser closed in the
/// transaction, the runtime gone). With the fence no main-thread wait reaches the fork; an older
/// fork keeps the API 27 deadlines.
@MainActor
@Suite struct CEFResizeFencesTests {
    /// Core Animation without a render server: contexts by view, fences made, held, released, and
    /// the post-commit handlers of the open transaction.
    final class FakeCA {
        var contexts: [ObjectIdentifier: ObjectIdentifier] = [:]
        private(set) var made: [mach_port_t] = []
        private(set) var held: [(context: ObjectIdentifier, fence: mach_port_t)] = []
        private(set) var released: [mach_port_t] = []
        private var afterCommit: [@MainActor () -> Void] = []
        private var next: mach_port_t = 100

        /// `view` draws through the context of `window` (a stand-in object).
        func place(_ view: NSView, in window: AnyObject) {
            contexts[ObjectIdentifier(view)] = ObjectIdentifier(window)
        }

        var commit: CEFResizeFences.Commit {
            CEFResizeFences.Commit(
                context: { [self] view in
                    guard let id = contexts[ObjectIdentifier(view)] else { return nil }
                    return CEFResizeFences.Context(id: id, createFence: { [self] in
                        next += 1
                        made.append(next)
                        return next
                    }, holdCommit: { [self] fence in held.append((id, fence)) })
                },
                afterCommit: { [self] block in afterCommit.append(block) },
                release: { [self] fence in released.append(fence) })
        }

        /// The open transaction commits.
        func commitTransaction() {
            let due = afterCommit
            afterCommit = []
            for block in due { block() }
        }
    }

    /// The fork's `cmux_browser_set_resize_fence`: every call, and which browsers are closed.
    final class FakeFenceFork {
        private(set) var calls: [(browser: Int32, fence: mach_port_t, frames: UInt32)] = []
        var closed: Set<Int32> = []
        var set: CEFResizeFences.SetFence {
            { [self] browser, fence, frames in
                calls.append((browser, fence, frames))
                return !closed.contains(browser)
            }
        }
    }

    let ca = FakeCA()
    let fork = FakeFenceFork()
    let window = NSObject()

    func view() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        ca.place(view, in: window)
        return view
    }

    @Test func everyPageResizedInOneTransactionSharesOneFenceHeldOnce() {
        let fences = CEFResizeFences(commit: ca.commit)
        let left = view(), right = view()
        #expect(fences.join(left, browser: 3, setFence: fork.set))
        #expect(fences.join(right, browser: 4, setFence: fork.set))
        #expect(ca.made.count == 1)
        #expect(fences.fencesMade == 1)
        let fence = ca.made[0]
        #expect(fork.calls.map(\.browser) == [3, 4])
        #expect(fork.calls.allSatisfy { $0.fence == fence && $0.frames == CEFResizeFences.deadlineFrames })
        #expect(CEFResizeFences.deadlineFrames == 2)
        // The window's context holds its commit once for the transaction.
        #expect(ca.held.map(\.fence) == [fence])
        // The app's right goes only after the commit.
        #expect(ca.released.isEmpty)
        ca.commitTransaction()
        #expect(ca.released == [fence])
        #expect(fences.fencesReleased == 1)
    }

    @Test func theNextTransactionMakesANewFence() {
        let fences = CEFResizeFences(commit: ca.commit)
        let page = view()
        // A divider drag: one transaction per event.
        for _ in 0..<3 {
            fences.join(page, browser: 3, setFence: fork.set)
            fences.join(page, browser: 3, setFence: fork.set)
            ca.commitTransaction()
        }
        #expect(ca.made.count == 3)
        #expect(ca.released == ca.made)
        #expect(ca.held.map(\.fence) == ca.made)
        #expect(fork.calls.map(\.fence) == ca.made)
    }

    @Test func eachWindowContextHoldsTheSameFence() {
        let fences = CEFResizeFences(commit: ca.commit)
        let other = NSObject()
        let here = view()
        let there = NSView(frame: .zero)
        ca.place(there, in: other)
        fences.join(here, browser: 3, setFence: fork.set)
        fences.join(there, browser: 4, setFence: fork.set)
        #expect(ca.made.count == 1)
        #expect(ca.held.map(\.context) == [ObjectIdentifier(window), ObjectIdentifier(other)])
        #expect(Set(ca.held.map(\.fence)) == [ca.made[0]])
    }

    /// A browser closed in the transaction: the fork refuses, the window does not wait for it,
    /// and the app's right still goes after the commit.
    @Test func aBrowserClosedMidTransactionStillReleasesTheFence() {
        let fences = CEFResizeFences(commit: ca.commit)
        fork.closed = [3]
        #expect(!fences.join(view(), browser: 3, setFence: fork.set))
        #expect(ca.held.isEmpty)
        #expect(fences.joins == 0)
        ca.commitTransaction()
        #expect(ca.released == ca.made)
        #expect(ca.made.count == 1)
    }

    @Test func theRightGoesAfterTheCommitEvenWhenTheRuntimeIsGone() {
        var fences: CEFResizeFences? = CEFResizeFences(commit: ca.commit)
        fences?.join(view(), browser: 3, setFence: fork.set)
        fences = nil
        ca.commitTransaction()
        #expect(ca.released == ca.made)
        #expect(ca.made.count == 1)
    }

    @Test func aViewOutsideAWindowMakesNoFence() {
        let fences = CEFResizeFences(commit: ca.commit)
        #expect(!fences.join(NSView(frame: .zero), browser: 3, setFence: fork.set))
        #expect(ca.made.isEmpty)
        #expect(fork.calls.isEmpty)
    }
}

/// `CEFLayerHosting` on a fork with the resize fence: which resizes join, and that the deadline
/// call (Chromium's commit wait) never runs.
@MainActor
@Suite struct CEFLayerHostingResizeFenceTests {
    let ca = CEFResizeFencesTests.FakeCA()
    let fenceFork = CEFResizeFencesTests.FakeFenceFork()
    let layerFork = CEFLayerHostingTests.FakeFork()
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    let fences: CEFResizeFences

    init() {
        fences = CEFResizeFences(commit: ca.commit)
        ca.place(view, in: window)
    }

    let window = NSObject()

    /// The fork with both calls: the fence takes the place of the API 27 deadline.
    var fork: CEFLayerHosting.Fork {
        let base = layerFork.fork
        return CEFLayerHosting.Fork(setLayerHosting: base.setLayerHosting, setResizeSync: base.setResizeSync,
                                    resizeFence: CEFLayerHosting.ResizeFence(fences: fences, set: fenceFork.set))
    }

    func makeHosting(enabled: Bool) -> CEFLayerHosting {
        let hosting = CEFLayerHosting(isEnabled: { enabled }, schedule: { $0() },
                                      makePage: { ChromiumHostPageView(frame: $0, inputTarget: .pageWindow, makeLayerHost: { _ in CALayer() }) },
                                      resizeDeadlineMs: { 8 }, liveResizeDeadlineMs: { 50 }, refreshIntervals: { [] })
        hosting.view = view
        return hosting
    }

    @Test func aHostedPageJoinsEveryResizeAndNoDeadlineReachesTheFork() {
        let hosting = makeHosting(enabled: true)
        hosting.pageWindowCreated(browser: 5, fork: fork)
        #expect(hosting.page != nil)
        hosting.viewDidResize()
        hosting.viewDidResize()
        ca.commitTransaction()
        hosting.windowLiveResize(active: true)
        hosting.viewDidResize()
        hosting.windowLiveResize(active: false)
        hosting.displaysChanged()
        hosting.pageShown(browser: 5)
        ca.commitTransaction()
        // One join per transaction, however often its layout resized the view.
        #expect(fenceFork.calls.map(\.browser) == [5, 5])
        #expect(ca.made.count == 2)
        #expect(ca.released == ca.made)
        // No main-thread wait: the API 27 deadline call never runs.
        #expect(layerFork.syncs.isEmpty)
    }

    @Test func aPageInItsOwnWindowJoinsOnlyDuringTheWindowsLiveResize() {
        let hosting = makeHosting(enabled: false)
        hosting.pageWindowCreated(browser: 4, fork: fork)
        hosting.viewDidResize()
        #expect(fenceFork.calls.isEmpty)
        hosting.windowLiveResize(active: true)
        hosting.viewDidResize()
        hosting.windowLiveResize(active: false)
        hosting.viewDidResize()
        ca.commitTransaction()
        #expect(fenceFork.calls.map(\.browser) == [4])
        #expect(ca.released == ca.made)
        #expect(layerFork.syncs.isEmpty)
    }

    @Test func aViewOutOfEveryWindowMakesNoFence() {
        let hosting = makeHosting(enabled: true)
        hosting.pageWindowCreated(browser: 5, fork: fork)
        ca.contexts = [:]
        hosting.viewDidResize()
        #expect(fenceFork.calls.isEmpty)
        #expect(ca.made.isEmpty)
    }

    /// An older fork (API 27 to 30) has no fence: a resize makes no fence and the deadlines stay.
    @Test func anOlderForkKeepsTheAPI27Deadlines() {
        let hosting = makeHosting(enabled: true)
        hosting.pageWindowCreated(browser: 5, fork: layerFork.fork)
        hosting.viewDidResize()
        #expect(ca.made.isEmpty)
        #expect(layerFork.syncs.map(\.timeoutMs) == [8])
    }
}

/// The shim side: the fence call exists only from ``CEFLayerHosting/resizeFenceForkAPI`` in
/// process, and its presence drops the deadline call.
@MainActor
@Suite(.serialized) struct CEFResizeFenceShimTests {
    nonisolated(unsafe) static var fenceCalls: [(browser: Int32, fence: UInt32, frames: UInt32)] = []

    static func shim(hostExports: Set<String>? = nil) throws -> CEFShimLibrary {
        let setFence: @convention(c) (Int32, UInt32, UInt32) -> Int32 = { browser, fence, frames in
            CEFResizeFenceShimTests.fenceCalls.append((browser, fence, frames))
            return 1
        }
        let nothing: @convention(c) () -> Int = { 0 }
        let symbol: (String) -> UnsafeMutableRawPointer? = { name in
            name == "cmux_shim_browser_set_resize_fence"
                ? unsafeBitCast(setFence, to: UnsafeMutableRawPointer.self)
                : unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
        if let hostExports { return try CEFShimLibrary.resolving(symbol, hostExports: hostExports) }
        return try CEFShimLibrary.resolving(symbol)
    }

    @Test func aForkWithTheFenceGetsNoDeadlineCall() throws {
        Self.fenceCalls = []
        let ca = CEFResizeFencesTests.FakeCA()
        let fences = CEFResizeFences(commit: ca.commit)
        let fork = try #require(CEFLayerHosting.Fork(shim: try Self.shim(), apiVersion: CEFLayerHosting.resizeFenceForkAPI, fences: fences))
        #expect(fork.setResizeSync == nil)
        let resizeFence = try #require(fork.resizeFence)
        let view = NSView(frame: .zero)
        ca.place(view, in: NSObject())
        #expect(resizeFence.fences.join(view, browser: 9, setFence: resizeFence.set))
        #expect(Self.fenceCalls.map(\.browser) == [9])
        #expect(Self.fenceCalls.map(\.frames) == [2])
        #expect(Self.fenceCalls.map(\.fence) == ca.made)
    }

    @Test func anOlderForkKeepsTheDeadlineCall() throws {
        let fences = CEFResizeFences(commit: CEFResizeFencesTests.FakeCA().commit)
        let fork = try #require(CEFLayerHosting.Fork(shim: try Self.shim(), apiVersion: CEFLayerHosting.resizeFenceForkAPI - 1, fences: fences))
        #expect(fork.resizeFence == nil)
        #expect(fork.setResizeSync != nil)
    }

    /// A Mach port name means nothing in the Chromium Host's process.
    @Test func hostModeHasNoFence() throws {
        let shim = try Self.shim(hostExports: ["cmux_shim_browser_set_resize_fence"])
        #expect(shim.browserSetResizeFence == nil)
        let fences = CEFResizeFences(commit: CEFResizeFencesTests.FakeCA().commit)
        let fork = try #require(CEFLayerHosting.Fork(shim: shim, apiVersion: CEFLayerHosting.resizeFenceForkAPI, fences: fences))
        #expect(fork.resizeFence == nil)
        #expect(fork.setResizeSync != nil)
    }
}
