import AppKit
import Foundation
import Testing
@testable import CmuxNextApp

/// Waits on main (bounded) until `done` holds.
@MainActor
private func waitOnMain(_ done: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(5)
    while !done(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

/// The keyboard layout notice comes through one Core Foundation distributed
/// registration (`.deliverImmediately`, also in the background); its C
/// callback may run on any thread, and the observers must run on main. The
/// selector observer it replaces targeted a main-actor object and trapped on
/// an off-main delivery (plans/cmux-next/crash-elimination.md, P1b).
@MainActor @Suite(.serialized)
struct KeyboardLayoutObserverTests {
    @MainActor final class Calls {
        var count = 0
        var offMain = 0
        func record() {
            count += 1
            if !Thread.isMainThread { offMain += 1 }
        }
    }

    /// The keyboard layout callback arrives on whatever thread Core
    /// Foundation picks: the observers run on main.
    @Test func aLayoutChangeOffMainCallsTheObserverOnMain() async {
        let calls = Calls()
        let observer = KeyboardLayoutObserver { calls.record() }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread {
                keyboardLayoutDidChange(nil, nil, nil, nil, nil)
                done.resume()
            }
        }
        await waitOnMain { calls.count > 0 }
        #expect(calls.count == 1)
        #expect(calls.offMain == 0)
        _ = observer
    }

    /// A released observer is not called.
    @Test func aReleasedLayoutObserverIsNotCalled() {
        let calls = Calls()
        var observer: KeyboardLayoutObserver? = KeyboardLayoutObserver { calls.record() }
        #expect(observer != nil)
        observer = nil
        KeyboardLayoutObserver.layoutChanged()
        #expect(calls.count == 0)
    }
}
