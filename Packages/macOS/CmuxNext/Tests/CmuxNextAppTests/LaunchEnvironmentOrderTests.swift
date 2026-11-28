import Synchronization
import Testing
import CmuxNextProcessEnvironment
@testable import CmuxNextApp

/// The real launch order: every environment write of `main` runs before the
/// freeze that precedes the first thread and `ghostty_init`.
@Suite struct LaunchEnvironmentOrderTests {
    private final class Violations: Sendable {
        let count = Atomic<Int>(0)
    }

    @Test func launchOrderFreezesOnlyAfterTheThreeWrites() {
        let violations = Violations()
        // performsWrites false: the test process keeps its environment.
        let environmentGuard = ProcessEnvironmentGuard(performsWrites: false) { _ in
            violations.count.add(1, ordering: .relaxed)
        }
        CmuxNextApp.prepareLaunchEnvironment(environmentGuard: environmentGuard)
        #expect(environmentGuard.isFrozen)
        #expect(environmentGuard.writesBeforeFreeze == 3)
        #expect(violations.count.load(ordering: .relaxed) == 0)
    }
}
