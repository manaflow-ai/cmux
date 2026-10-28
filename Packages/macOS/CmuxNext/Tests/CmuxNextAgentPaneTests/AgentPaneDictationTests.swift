import AppKit
import CmuxNextDictation
import CmuxNextPages
import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextAgentPane
@testable import CmuxNextInput

/// Hold-to-talk hears the held shortcut's release through the app's input tap (p04-input-017): a key-up
/// and modifier subscription that exists only while a hold is armed, and leaves the tap at the release,
/// a quick press, or the pane's close.
@Suite(.serialized)
@MainActor
struct AgentPaneDictationTests {
    /// Permissions never answered while a test runs: the session stays starting, as one does while the
    /// person still holds the key.
    private struct WaitingAuthorizer: DictationAuthorizing {
        func microphoneAuthorization() async -> DictationAuthorizationStatus { .undetermined }
        func requestMicrophoneAuthorization() async -> Bool { false }
        func speechRecognitionAuthorization() async -> DictationAuthorizationStatus { .undetermined }
        func requestSpeechRecognitionAuthorization() async -> Bool { false }
    }

    /// The Option-Command-V shortcut's key code (`kVK_ANSI_V`).
    private static let shortcutKey: UInt16 = 9
    private static let chord: NSEvent.ModifierFlags = [.command, .option]

    private final class Harness {
        let tap = InputEventTap()
        let dictation: AgentPaneDictation
        let pressedAt = ProcessInfo.processInfo.systemUptime
        /// The app's notices (resign) and the workspace's (sleep), each on a center of the test's own.
        let appCenter = NotificationCenter(), workspaceCenter = NotificationCenter()
        let appEvents: AppEvents, workspaceEvents: AppEvents

        init() {
            (appEvents, workspaceEvents) = (AppEvents(center: appCenter), AppEvents(center: workspaceCenter))
            let deadlines = MainDeadlineScheduler(work: MainWorkScheduler(budget: MainFrameBudget()))
            let mainThread = AgentPaneMainThread(deadlines: deadlines, appEvents: appEvents, workspaceEvents: workspaceEvents)
            dictation = AgentPaneDictation(input: tap, mainThread: mainThread, send: { _ in }, microphone: DictationMicrophone(),
                                           makeSession: { DictationSession(deadlines: deadlines, authorizer: WaitingAuthorizer()) })
            let pressedAt = pressedAt
            dictation.now = { pressedAt }
        }

        var releaseSubscriptions: Int {
            tap.subscriberCount(.key, stage: .observe) + tap.subscriberCount(.flags, stage: .observe)
        }

        func key(_ type: NSEvent.EventType, after seconds: TimeInterval, flags: NSEvent.ModifierFlags = AgentPaneDictationTests.chord,
                 keyCode: UInt16 = AgentPaneDictationTests.shortcutKey) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: pressedAt + seconds,
                                          windowNumber: 0, context: nil, characters: "v", charactersIgnoringModifiers: "v",
                                          isARepeat: false, keyCode: keyCode))
        }

        func flags(_ flags: NSEvent.ModifierFlags, after seconds: TimeInterval) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: pressedAt + seconds,
                                          windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                          isARepeat: false, keyCode: 58))
        }

        func dispatch(_ event: NSEvent) {
            tap.dispatching {
                tap.deliverObserve(event)
                _ = tap.deliverIntercepts(event)
                tap.deliverAfterDispatch(event)
            }
        }

        /// The shortcut's key-down starts dictation and arms the hold.
        func press() throws {
            dictation.toggle(from: try key(.keyDown, after: 0))
        }
    }

    @Test func aHoldSubscribesOnlyWhileArmedAndItsReleaseStopsDictation() throws {
        let harness = Harness()
        #expect(harness.releaseSubscriptions == 0, "an idle pane costs the tap nothing")
        try harness.press()
        #expect(!harness.dictation.phase.isStartable, "the shortcut did not start dictation")
        #expect(harness.releaseSubscriptions == 2, "the hold hears key-ups and modifier changes")

        harness.dispatch(try harness.key(.keyUp, after: AgentPaneDictation.holdThreshold + 0.1))
        #expect(harness.dictation.phase.isStartable, "releasing a held shortcut did not stop dictation")
        #expect(harness.releaseSubscriptions == 0, "the release left its subscription on the tap")
        #expect(!harness.dictation.holdsResources)
    }

    /// Rule 9 (p06-scheduler.md): the app's resign and the Mac's sleep reach dictation through the app's one
    /// observer per notice (AppEvents), only while they matter: a resign ends an armed hold, sleep stops a running
    /// session, and an idle pane holds no subscription. Before, each pane made its own NotificationCenter observers.
    @Test func resignAndSleepComeThroughTheAppsFanOutsOnlyWhileTheyMatter() throws {
        let harness = Harness()
        #expect(harness.appEvents.subscriberCount(NSApplication.didResignActiveNotification) == 0)
        #expect(harness.workspaceEvents.subscriberCount(NSWorkspace.willSleepNotification) == 0, "an idle pane observes sleep")
        try harness.press()
        #expect(harness.appEvents.subscriberCount(NSApplication.didResignActiveNotification) == 1, "the hold does not hear the resign")
        #expect(harness.workspaceEvents.subscriberCount(NSWorkspace.willSleepNotification) == 1, "the session does not hear sleep")
        harness.appCenter.post(name: NSApplication.didResignActiveNotification, object: nil)
        #expect(harness.releaseSubscriptions == 0, "the resign left the hold armed")
        #expect(harness.appEvents.subscriberCount(NSApplication.didResignActiveNotification) == 0)
        #expect(!harness.dictation.phase.isStartable, "the resign stopped the session; only the hold ends")
        harness.workspaceCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(harness.dictation.phase.isStartable, "sleep did not stop the session")
        harness.dictation.close()
        #expect(!harness.dictation.holdsResources)
    }

    @Test func aQuickPressKeepsDictatingAndDropsTheSubscription() throws {
        let harness = Harness()
        try harness.press()
        harness.dispatch(try harness.key(.keyUp, after: 0.05))
        #expect(!harness.dictation.phase.isStartable, "a quick press stopped dictation")
        #expect(harness.releaseSubscriptions == 0)
        harness.dictation.close()
    }

    @Test func aModifierLetGoFirstIsTheRelease() throws {
        let harness = Harness()
        try harness.press()
        harness.dispatch(try harness.key(.keyDown, after: 0.1, keyCode: 0))
        #expect(harness.releaseSubscriptions == 2, "another key-down is not the release")
        harness.dispatch(try harness.flags([.command], after: AgentPaneDictation.holdThreshold + 0.1))
        #expect(harness.dictation.phase.isStartable)
        #expect(harness.releaseSubscriptions == 0)
    }

    @Test func closingThePaneMidHoldLeavesNothingOnTheTap() throws {
        let harness = Harness()
        try harness.press()
        #expect(harness.releaseSubscriptions == 2)
        harness.dictation.close()
        #expect(harness.releaseSubscriptions == 0)
        #expect(!harness.dictation.holdsResources)
    }

    /// A session holds its page's `dictation` keep reason (p13-webui-032), so a hidden chat is not
    /// frozen or discarded while it still takes words: one begin as it starts, one end as it stops
    /// or as the pane closes, and never one more.
    @Test func aSessionHoldsItsPagesDictationReasonUntilItEnds() throws {
        let harness = Harness()
        let keep = PageKeepReasons()
        var changes: [Bool] = []
        harness.dictation.onRunning = { running in
            changes.append(running)
            keep.dictation(running)
        }
        try harness.press()
        #expect(changes == [true])
        #expect(keep.current.contains(.dictation))
        harness.dispatch(try harness.key(.keyUp, after: AgentPaneDictation.holdThreshold + 0.1))
        #expect(harness.dictation.phase.isStartable)
        #expect(changes == [true, false])
        #expect(keep.current.isEmpty)
        try harness.press()
        harness.dictation.close()
        #expect(changes == [true, false, true, false], "closing mid-session left the hold")
        #expect(keep.current.isEmpty)
        harness.dictation.close()
        #expect(changes == [true, false, true, false], "a second close ended a hold it did not have")
    }
}
