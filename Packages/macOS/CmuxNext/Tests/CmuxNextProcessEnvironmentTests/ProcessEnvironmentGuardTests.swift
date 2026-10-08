import Synchronization
import Testing
import CmuxNextProcessEnvironment

/// Collects violations from a guard instead of stopping the test process.
private final class ViolationLog: Sendable {
    private let messages = Mutex<[String]>([])
    var all: [String] { messages.withLock { $0 } }
    func record(_ message: String) { messages.withLock { $0.append(message) } }
}

@Suite struct ProcessEnvironmentGuardTests {
    @Test func writeBeforeFreezeRuns() {
        let log = ViolationLog()
        let environmentGuard = ProcessEnvironmentGuard(onViolation: log.record)
        var ran = false
        environmentGuard.write("test.before") { ran = true }
        #expect(ran)
        #expect(environmentGuard.writesBeforeFreeze == 1)
        #expect(log.all.isEmpty)
    }

    @Test func writeAfterFreezeHitsTheFailureHandlerAndIsSkipped() {
        let log = ViolationLog()
        let environmentGuard = ProcessEnvironmentGuard(onViolation: log.record)
        environmentGuard.freeze()
        var ran = false
        environmentGuard.write("test.after") { ran = true }
        environmentGuard.write("test.after") { ran = true }
        #expect(!ran)
        #expect(environmentGuard.writesBeforeFreeze == 0)
        #expect(log.all.count == 2)
        #expect(log.all.first?.contains("test.after") == true)
    }

    @Test func dryRunGuardCountsWithoutRunningTheBody() {
        let environmentGuard = ProcessEnvironmentGuard(performsWrites: false) { _ in }
        var ran = false
        environmentGuard.write("test.dry") { ran = true }
        #expect(!ran)
        #expect(environmentGuard.writesBeforeFreeze == 1)
    }
}
