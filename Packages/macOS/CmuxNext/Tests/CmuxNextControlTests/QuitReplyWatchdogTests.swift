import CmuxNextCompat
import CmuxNextControl
import Foundation
import Testing

/// A relaunch, keep sessions, hung a NIGHTLY for good: `NSApp.terminate` ran inside a main-actor
/// Task, `applicationShouldTerminate` answered `.terminateLater`, and AppKit's nested run loop waited
/// for a reply a main-actor Task was to send, which never ran (the main queue is serial and the job
/// that called terminate never returned). These tests take that shape for real: the test body is a
/// main-actor job, the reply is a main-actor Task, and the wait is a nested run of the main run loop
/// in AppKit's modal panel mode.
@MainActor
@Suite(.serialized)
struct QuitReplyWatchdogTests {
    @MainActor final class Replies {
        var all: [String] = []
    }

    /// AppKit's terminateLater wait: the main run loop in the modal panel mode (a common mode, as
    /// AppKit makes it) until `replied()` or `bound` passes. Returns the seconds it waited.
    private static func waitForReply(bound: TimeInterval, _ replied: () -> Bool) -> TimeInterval {
        let modal = RunLoop.Mode("NSModalPanelRunLoopMode")
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(modal.rawValue as CFString))
        let began = Date()
        let end = began.addingTimeInterval(bound)
        while !replied(), Date() < end {
            // concurrency-allow: the test stands in for AppKit's terminateLater nested run loop.
            _ = RunLoop.main.run(mode: modal, before: Date().addingTimeInterval(0.02))
        }
        return Date().timeIntervalSince(began)
    }

    /// terminate inside a main-actor job: the quit's own Task cannot reply; the watchdog does, in time.
    @Test func aQuitAskedInsideAMainActorJobRepliesWithinTheWatchdogLimit() {
        let replies = Replies()
        // As `QuitCoordinator.shouldTerminate`: a started watchdog, the reply Task, then terminateLater's wait.
        let reply = QuitReplyWatchdog.started(limit: .milliseconds(200)) { replies.all.append("quits=\($0)") }
        Task { @MainActor in reply.send(false) }
        let waited = Self.waitForReply(bound: 5) { !replies.all.isEmpty }
        #expect(replies.all == ["quits=true"], "the reply was \(replies.all)")
        #expect(waited < 2, "no reply within the watchdog's limit: waited \(waited) s")
        #expect(reply.fired)
    }

    /// terminate from a run-loop callout (`NSApplication.terminateFromRunLoop`): the quit's own Task
    /// replies inside the wait, and the watchdog never fires.
    @Test func aQuitAskedFromARunLoopCalloutGetsItsOwnReply() async {
        let replies = Replies()
        let reply = QuitReplyWatchdog(limit: .seconds(3)) { replies.all.append("quits=\($0)") }
        let waited: TimeInterval = await withCheckedContinuation { done in
            MainRunLoopBlock.perform {
                reply.start()
                Task { @MainActor in reply.send(false) }
                done.resume(returning: Self.waitForReply(bound: 5) { !replies.all.isEmpty })
            }
        }
        #expect(replies.all == ["quits=false"], "the quit's own reply did not run inside the wait: \(replies.all)")
        #expect(waited < 2)
        #expect(!reply.fired)
        #expect(!reply.isArmed)
    }

    /// While the person answers the limit does not count; it counts again from the answer, and the
    /// reply goes once whoever sends it.
    @Test func aHeldWatchdogNeverFiresAndTheReplyGoesOnce() async {
        let replies = Replies()
        let reply = QuitReplyWatchdog.started(limit: .milliseconds(100)) { replies.all.append("quits=\($0)") }
        let answered = await reply.holding {
            _ = Self.waitForReply(bound: 0.3) { false }
            return true
        }
        #expect(answered)
        #expect(replies.all.isEmpty, "a held watchdog replied")
        #expect(reply.isArmed, "the watchdog did not count again after the answer")
        _ = Self.waitForReply(bound: 5) { !replies.all.isEmpty }
        #expect(replies.all == ["quits=true"])
        reply.send(false)
        reply.start()
        _ = Self.waitForReply(bound: 0.3) { false }
        #expect(replies.all == ["quits=true"], "AppKit got a second reply")
    }
}
