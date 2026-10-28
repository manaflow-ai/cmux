import AppKit
import CmuxNextInput
@testable import CmuxNextTerminal
import CmuxNextWakeups
import Testing

/// The terminals' one modifier watch on the app's input tap: Command pressed or released over
/// a terminal without focus reaches the terminal under the pointer and no other. The watch holds one flags
/// subscription while some terminal is under the pointer and none otherwise, however many terminals there are.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct TerminalLinkPointerTests {
    /// Sessions on scripted IO that share one watch on `tap`.
    final class Harness {
        let tap = InputEventTap()
        let watch: TerminalModifierWatch
        private(set) var sessions: [(session: TerminalSession, io: ScriptedTerminalIO)] = []

        init(terminals: Int) {
            _ = NSApplication.shared
            GhosttyRuntime.startedForTests()
            watch = TerminalModifierWatch(input: tap)
            for _ in 0..<terminals {
                let io = ScriptedTerminalIO()
                sessions.append((TerminalSession(io: io, modifiers: watch, mainWork: MainWorkScheduler(budget: MainFrameBudget())), io))
            }
        }

        func pointer(_ index: Int) -> TerminalLinkPointer { sessions[index].session.surfaceView.linkPointer }

        /// The pointer moved over terminal `index`, as its mouse-moved handler reports it.
        func move(over index: Int) { pointer(index).moved(to: NSPoint(x: 10, y: 10), flags: []) }

        var flagsSubscriptions: Int { tap.subscriberCount(.flags, stage: .observe) }

        func flagsChanged(_ flags: NSEvent.ModifierFlags) throws {
            let event = try #require(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 1,
                                                      windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                                      isARepeat: false, keyCode: 55))
            tap.dispatching {
                tap.deliverObserve(event)
                _ = tap.deliverIntercepts(event)
                tap.deliverAfterDispatch(event)
            }
        }

        func close() {
            for (session, io) in sessions {
                io.finish()
                session.close()
            }
        }
    }

    @Test func noTerminalUnderThePointerHoldsNoSubscription() {
        let harness = Harness(terminals: 3)
        defer { harness.close() }
        #expect(harness.flagsSubscriptions == 0)
        #expect(!harness.watch.isWatching)
    }

    @Test func theTerminalUnderThePointerIsTheOnlyOneTracked() {
        let harness = Harness(terminals: 3)
        defer { harness.close() }
        harness.move(over: 0)
        #expect(harness.watch.isTracking(harness.pointer(0)))
        #expect(harness.flagsSubscriptions == 1)
        harness.move(over: 0)
        #expect(harness.flagsSubscriptions == 1, "a second move over the same terminal subscribed again")
        // The pointer reaches another terminal before the first one's exit is handled.
        harness.move(over: 1)
        #expect(harness.watch.isTracking(harness.pointer(1)))
        #expect(!harness.watch.isTracking(harness.pointer(0)))
        #expect(harness.flagsSubscriptions == 1, "two terminals under one pointer: \(harness.flagsSubscriptions) subscriptions")
        // The first terminal's late exit leaves the watch on the second.
        harness.pointer(0).exited()
        #expect(harness.watch.isTracking(harness.pointer(1)))
        #expect(harness.flagsSubscriptions == 1)
    }

    @Test func aModifierChangeReachesOnlyTheTerminalUnderThePointer() throws {
        let harness = Harness(terminals: 3)
        defer { harness.close() }
        harness.move(over: 1)
        try harness.flagsChanged(.command)
        #expect(harness.pointer(1).heardModifierChanges == 1, "Command did not reach the terminal under the pointer")
        #expect(harness.pointer(1).lastHeardModifiers?.contains(.command) == true,
                "the terminal heard \(String(describing: harness.pointer(1).lastHeardModifiers)), not Command")
        try harness.flagsChanged([])
        #expect(harness.pointer(1).heardModifierChanges == 2)
        #expect(harness.pointer(1).lastHeardModifiers?.contains(.command) == false, "the release did not reach it")
        #expect(harness.pointer(0).heardModifierChanges == 0, "a terminal not under the pointer heard the change")
        #expect(harness.pointer(2).heardModifierChanges == 0, "a terminal not under the pointer heard the change")
        // The pointer moves on: the next change goes to the new terminal only.
        harness.move(over: 2)
        try harness.flagsChanged(.command)
        #expect(harness.pointer(2).heardModifierChanges == 1)
        #expect(harness.pointer(1).heardModifierChanges == 2, "the terminal the pointer left still heard a change")
    }

    @Test func thePointerLeavingItsTerminalGivesTheSubscriptionBack() throws {
        let harness = Harness(terminals: 2)
        defer { harness.close() }
        harness.move(over: 1)
        try harness.flagsChanged(.command)
        try harness.flagsChanged([])
        #expect(harness.watch.isTracking(harness.pointer(1)), "a modifier change ended the watch")
        harness.pointer(1).exited()
        #expect(!harness.watch.isWatching)
        #expect(harness.flagsSubscriptions == 0)
        try harness.flagsChanged(.command)
        #expect(harness.pointer(1).heardModifierChanges == 2, "a change after the pointer left reached its terminal")
        #expect(harness.pointer(0).heardModifierChanges == 0)
    }

    @Test func aSessionWithoutAWatchHearsNoModifierChange() throws {
        let harness = Harness(terminals: 1)
        let io = ScriptedTerminalIO()
        let unwatched = TerminalSession(io: io, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        defer {
            io.finish()
            unwatched.close()
            harness.close()
        }
        unwatched.surfaceView.linkPointer.moved(to: NSPoint(x: 10, y: 10), flags: [])
        #expect(harness.flagsSubscriptions == 0, "a session without the watch subscribed to the tap")
        harness.move(over: 0)
        try harness.flagsChanged(.command)
        #expect(harness.pointer(0).heardModifierChanges == 1)
        #expect(unwatched.surfaceView.linkPointer.heardModifierChanges == 0, "a session without the watch heard the change")
    }
}
