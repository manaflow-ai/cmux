import Foundation
import Testing
@testable import CmuxNextBrowserAutomation

/// The driver's waits on WebKit private callbacks
/// (`_doAfterActivityStateUpdate:`) and its private calls' OS gate, on a
/// `WebKitPrivateCalls` value with its OS version, clock and bound injected.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct WebKitPrivateCallTests {
    private func calls(osMajor: Int = 27, bound: Duration) -> WebKitPrivateCalls {
        WebKitPrivateCalls(osMajor: osMajor, clock: ContinuousClock(), callbackBound: bound)
    }

    /// A torn-down view never calls the block: the wait ends at its bound.
    @Test func aCallbackThatNeverComesEndsAtTheBound() async {
        let ran = await calls(bound: .milliseconds(50)).awaitCallback { _ in }
        #expect(ran == false)
    }

    /// A block WebKit calls twice resumes the wait once (no double-resume trap).
    @Test func aCallbackCalledTwiceResumesOnce() async {
        let ran = await calls(bound: .seconds(30)).awaitCallback { done in
            done()
            done()
        }
        #expect(ran == true)
    }

    /// A cancelled wait ends at once.
    @Test func aCancelledWaitEnds() async {
        let calls = calls(bound: .seconds(30))
        let waiting = Task { await calls.awaitCallback { _ in } }
        waiting.cancel()
        #expect(await waiting.value == false)
    }

    /// The private signatures are trusted only on the macOS versions they
    /// were verified on (26 and 27); any other version takes the public path.
    @Test func privateCallsRunOnlyOnVerifiedVersions() {
        #expect(calls(osMajor: 27, bound: .seconds(1)).isVerified)
        #expect(calls(osMajor: 26, bound: .seconds(1)).isVerified)
        #expect(!calls(osMajor: 25, bound: .seconds(1)).isVerified)
        #expect(!calls(osMajor: 28, bound: .seconds(1)).isVerified)
    }
}
