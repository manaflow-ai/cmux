import Foundation
import Testing
@testable import CmuxNextWakeups

@MainActor private final class Flag {
    var value = false
}

/// `MainDelivery` runs inline on main (no reordering) and hops from any
/// other thread instead of trapping.
@MainActor @Suite(.timeLimit(.minutes(1))) struct MainDeliveryTests {
    @Test func onMainTheWorkRunsBeforeRunReturns() {
        let flag = Flag()
        MainDelivery().run { flag.value = true }
        #expect(flag.value)
    }

    @Test func fromABackgroundThreadTheWorkLandsOnMain() async {
        let onMain = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            Thread.detachNewThread {
                MainDelivery().run { done.resume(returning: Thread.isMainThread) }
            }
        }
        #expect(onMain)
    }
}
