@testable import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Darwin
import Foundation
import os
import Testing

/// A relaunch whose last quit left a Chromium page on screen (a restored agent chat) reads Chromium's framework from
/// the app's `main` and lets `CefInitialize` run before the first frame (`CEFLaunchPrefetch`), instead of reading it at
/// the page's first ask and holding `CefInitialize` behind the frame that page is part of. These pin both halves and
/// the "nothing new without a saved page" rule; the read is a spy, so no framework loads.
@MainActor @Suite(.serialized)
struct CEFLaunchPrefetchTests {
    static let work = BackgroundWork(label: "test.cef-launch-prefetch")
    nonisolated static let layout: CEFRuntimeLayout = {
        let root = URL(filePath: "/nonexistent/cef-launch-prefetch")
        return CEFRuntimeLayout(frameworksDirectory: root, mainBundle: root, helperApp: root)
    }()

    /// A first-frame gate whose backstop never fires on its own.
    static func gate() -> FirstFrameGate { FirstFrameGate(backstop: DemandTimer(owner: "test", clock: ManualClock())) }

    /// Each read's thread: true on the main thread.
    nonisolated final class Reads: Sendable {
        private let state = OSAllocatedUnfairLock<[Bool]>(initialState: [])
        var onMain: [Bool] { state.withLock { $0 } }
        func read(_: CEFRuntimeLayout) { state.withLock { $0.append(pthread_main_np() != 0) } }
    }

    /// Runs `start`'s lane item to its end: a later item at the same priority runs after it (the lane is serial).
    static func drain() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            work.post(.userVisible, mayBlock: .files) { done.resume() }
        }
    }

    @Test func aSavedPageReadsTheFrameworkOffMainAndLetsCefInitializeRunBeforeTheFirstFrame() async {
        let reads = Reads(), firstFrame = Self.gate()
        let prefetch = CEFLaunchPrefetch(locate: { Self.layout }, read: { reads.read($0) })
        prefetch.start(on: Self.work) { true }
        await Self.drain()
        #expect(reads.onMain == [false], "the framework was not read once, off the main thread")
        #expect(prefetch.initializeGate(firstFrame) == nil, "CefInitialize still waits for the first frame the page is part of")
    }

    /// A launch whose last quit saved no page (Home, a terminal) reads nothing and keeps the first-frame gate.
    @Test func noSavedPageReadsNothingAndKeepsTheFirstFrameGate() async {
        let reads = Reads(), firstFrame = Self.gate()
        let prefetch = CEFLaunchPrefetch(locate: { Self.layout }, read: { reads.read($0) })
        prefetch.start(on: Self.work) { false }
        await Self.drain()
        #expect(reads.onMain.isEmpty, "a launch with no saved page read Chromium's framework")
        #expect(prefetch.initializeGate(firstFrame) === firstFrame, "a launch with no saved page dropped the first-frame gate")
    }

    /// The engine asked before the lane answered: the base behaviour (the first-frame gate), never a guess.
    @Test func anUnansweredLaneKeepsTheFirstFrameGate() {
        let firstFrame = Self.gate()
        let prefetch = CEFLaunchPrefetch(locate: { Self.layout }, read: { _ in })
        #expect(prefetch.initializeGate(firstFrame) === firstFrame)
    }
}
