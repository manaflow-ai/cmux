import AppKit
@testable import CmuxNextPages
import CmuxNextWakeups
import Foundation
import Testing

/// The pool follows a window that becomes key as background work on the app's scheduler
/// (p04-input-082): the key notice's turn, often the click or the key that changed windows, does
/// not re-park a spare nobody sees, and a person's pending input holds the move.
@MainActor @Suite(.serialized) struct PageHostPoolWindowFollowTests {
    fileprivate static let mainID = NSUserInterfaceItemIdentifier("PageHostPoolWindowFollowTests.main")

    @Test func aKeyWindowTakesTheSpareOnALaterTurn() {
        let rig = FollowRig()
        defer { rig.close() }
        rig.center.post(name: NSWindow.didBecomeKeyNotification, object: rig.second)
        #expect(rig.pool.target === rig.first, "the key notice's own turn moved the spare")
        #expect(rig.work.postedCount(.background) == 1, "the follow is not queued as background work")
        rig.runTurns()
        #expect(rig.pool.target === rig.second, "the posted follow never ran")
    }

    @Test func pendingInputHoldsTheFollow() {
        let rig = FollowRig()
        defer { rig.close() }
        rig.input.pending = true
        rig.center.post(name: NSWindow.didBecomeKeyNotification, object: rig.second)
        rig.runTurns()
        #expect(rig.pool.target === rig.first, "the follow ran while a person's input was pending")
        #expect(rig.work.postedCount(.background) == 1, "the held follow left its queue")
    }

    @Test func aClosedTargetFallsBackOnALaterTurn() {
        let rig = FollowRig(fallsBackToSecond: true)
        defer { rig.close() }
        rig.center.post(name: NSWindow.willCloseNotification, object: rig.first)
        #expect(rig.pool.target === rig.first, "the close notice's own turn moved the spare")
        rig.runTurns()
        #expect(rig.pool.target === rig.second)
    }
}

/// A pool started on a scheduler with no display link whose run loop turns the test runs, its
/// spare's target on `first`.
@MainActor private final class FollowRig {
    let input: FollowPendingInput
    let center: NotificationCenter
    let memory: PageTestMemory
    let work: MainWorkScheduler
    let pool: PageHostPool
    let first: NSWindow
    let second: NSWindow
    private let turns: FollowTurns

    init(fallsBackToSecond: Bool = false) {
        let input = FollowPendingInput(), memory = PageTestMemory(), turns = FollowTurns(), center = NotificationCenter()
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(input: input),
                                             performTurn: { turn in turns.queued.append(turn) }) { _ -> (any FrameLink)? in nil }
        let pool = PageHostPool(memory: memory.coordinator, activity: { 0 }, isTrackingMenu: { false })
        let first = FollowRig.mainWindow(), second = FollowRig.mainWindow()
        pool.start(isMainWindow: { $0.identifier == PageHostPoolWindowFollowTests.mainID },
                   fallback: { [weak second] _ in fallsBackToSecond ? second : nil }, mainWork: work, center: center)
        pool.windowDidAppear(first)
        self.input = input
        self.center = center
        self.memory = memory
        self.work = work
        self.pool = pool
        self.first = first
        self.second = second
        self.turns = turns
    }

    /// Runs the main run loop turns the scheduler queued, as the run loop would.
    func runTurns() {
        let queued = turns.queued
        turns.queued.removeAll()
        for turn in queued { turn() }
    }

    func close() {
        pool.dropSpare()
        first.close()
        second.close()
    }

    private static func mainWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -4_000, y: -4_000, width: 400, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.identifier = PageHostPoolWindowFollowTests.mainID
        return window
    }
}

@MainActor private final class FollowTurns {
    var queued: [@MainActor () -> Void] = []
}

@MainActor private final class FollowPendingInput: InputPendingSource {
    var pending = false
    func hasPendingInput(uptime: TimeInterval) -> Bool { pending }
}
