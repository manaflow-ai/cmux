import Foundation
import Testing
@testable import CmuxNextBrowserAutomation

/// The driver's waits on WebKit private callbacks
/// (`_doAfterActivityStateUpdate:`) and its private calls' OS gate.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct WebKitPrivateCallTests {
    /// A torn-down view never calls the block: the wait ends at its bound.
    @Test func aCallbackThatNeverComesEndsAtTheBound() async {
        let ran = await WebKitPrivateCalls.awaitCallback(bound: .milliseconds(50), clock: ContinuousClock()) { _ in }
        #expect(ran == false)
    }

    /// A block WebKit calls twice resumes the wait once (no double-resume trap).
    @Test func aCallbackCalledTwiceResumesOnce() async {
        let ran = await WebKitPrivateCalls.awaitCallback(bound: .seconds(30), clock: ContinuousClock()) { done in
            done()
            done()
        }
        #expect(ran == true)
    }

    /// A cancelled wait ends at once.
    @Test func aCancelledWaitEnds() async {
        let waiting = Task { await WebKitPrivateCalls.awaitCallback(bound: .seconds(30), clock: ContinuousClock()) { _ in } }
        waiting.cancel()
        #expect(await waiting.value == false)
    }

    /// The private signatures are trusted only on the macOS versions they
    /// were verified on (27); any other version takes the public path.
    @Test func privateCallsRunOnlyOnVerifiedVersions() {
        #expect(WebKitPrivateCalls.isVerified(osMajor: 27))
        #expect(!WebKitPrivateCalls.isVerified(osMajor: 26))
        #expect(!WebKitPrivateCalls.isVerified(osMajor: 28))
    }
}
