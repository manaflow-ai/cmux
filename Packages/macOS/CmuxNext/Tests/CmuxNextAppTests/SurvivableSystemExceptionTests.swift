@testable import CmuxNextCrashReporting
import Foundation
import Testing

/// #33743: dragging inside the Quick Look panel made QuickLookUI ask a mouse-drag event for its
/// touches; AppKit throws for that (`touchesMatchingPhase:inView:` takes gesture events only) and
/// every other app logs it, but cmux crashed on it. Only that exact system throw survives.
struct SurvivableSystemExceptionTests {
    static let reason = "Invalid message sent to event \"NSEvent: type=LMouseDragged loc=(555.98,363.52) time=794606.0 flags=0\""

    /// The NIGHTLY 1.0.0-nightly.4162023985101 crash of 2026-11-03, frames as `callStackSymbols` gives them.
    static let quickLookDragFrames = [
        "0   CoreFoundation   0x0000000198f2a8e8 __exceptionPreprocess + 164",
        "1   libobjc.A.dylib  0x0000000198a1e7c4 objc_exception_throw + 88",
        "2   Foundation       0x000000019a3c1b30 -[NSAssertionHandler handleFailureInMethod:object:file:lineNumber:description:] + 288",
        "3   AppKit           0x00000001a48d5634 -[NSEvent touchesMatchingPhase:inView:] + 428",
        "4   QuickLookUI      0x0000000242a7314c -[QLPanelPreviewView startDragFromGesture:beganOrFailedHandler:] + 124",
        "5   QuickLookUI      0x0000000242a70f2c -[QLPreviewView receivedDragGesture:] + 156",
        "6   AppKit           0x00000001a4b2c1d0 -[NSApplication(NSResponder) sendAction:to:from:] + 540",
        "7   AppKit           0x00000001a4f1a0e0 _NSGestureRecognizerSendOneAction + 60",
        "8   cmux             0x0000000100a1b2c4 cmux + 1234",
    ]

    /// What `reportException` did with the exception: recorded it for the next launch's crash
    /// notice, and handed it to AppKit (which crashes with `NSApplicationCrashOnExceptions`).
    struct Outcome: Equatable { var recorded: Bool; var reported: Bool }

    static func report(name: String = "NSInternalInconsistencyException", reason: String = reason,
                       frames: [String] = quickLookDragFrames) -> Outcome {
        let exception = NSException(name: NSExceptionName(name), reason: reason)
        var outcome = Outcome(recorded: false, reported: false)
        // crashes: false, so the test process never starts the crash deadline.
        CrashReporter.reportException(exception, frames: frames, crashes: false,
                                      record: { _ in outcome.recorded = true }, report: { outcome.reported = true })
        return outcome
    }

    @Test func theQuickLookPanelDragDoesNotCrash() {
        #expect(Self.report() == Outcome(recorded: false, reported: false), "the Quick Look drag throw reached AppKit's crash")
    }

    @Test func theSameThrowFromCmuxCodeStillCrashes() {
        var frames = Self.quickLookDragFrames
        frames[4] = "4   cmux   0x0000000100a1b2c4 CmuxNextApp.SomeView.mouseDragged(with:) + 80"
        #expect(Self.report(frames: frames) == Outcome(recorded: true, reported: true))
    }

    @Test func otherExceptionsStillCrash() {
        #expect(Self.report(name: "NSRangeException") == Outcome(recorded: true, reported: true))
        #expect(Self.report(reason: "layout pass") == Outcome(recorded: true, reported: true))
        #expect(Self.report(frames: []) == Outcome(recorded: true, reported: true))
    }
}
