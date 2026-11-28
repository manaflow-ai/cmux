import CmuxNextCompat
import CmuxNextProcessEnvironment
import Testing

/// The freeze gate: writes run before ``ProcessEnvironmentGuard/freeze()``, and after it they are
/// skipped and reported on every call.
@Suite struct ProcessEnvironmentGuardTests {
    @Test func aWriteBeforeTheFreezeRuns() {
        let gate = ProcessEnvironmentGuard(onViolation: { _ in Issue.record("no violation before the freeze") })
        var ran = false
        gate.write("before") { ran = true }
        #expect(ran)
        #expect(!gate.isFrozen)
    }

    @Test func aWriteAfterTheFreezeIsSkippedAndReportedEveryTime() {
        let violations = Violations()
        let gate = ProcessEnvironmentGuard(onViolation: { message in violations.record(message) })
        gate.freeze()
        gate.freeze()
        var ran = false
        gate.write("first") { ran = true }
        gate.write("second") { ran = true }
        #expect(gate.isFrozen)
        #expect(!ran)
        let seen = violations.all
        #expect(seen.count == 2)
        #expect(seen.first?.contains("first") == true)
        #expect(seen.last?.contains("second") == true)
    }

    @Test func aGuardThatPerformsNoWritesSkipsTheBodyBeforeTheFreeze() {
        let gate = ProcessEnvironmentGuard(performsWrites: false, onViolation: { _ in Issue.record("no violation before the freeze") })
        var ran = false
        gate.write("dry") { ran = true }
        #expect(!ran)
    }
}

/// The messages a guard reported, read after the writes.
private final class Violations: Sendable {
    private let messages = Mutex<[String]>([])

    func record(_ message: String) { messages.withLock { $0.append(message) } }

    var all: [String] { messages.withLock { $0 } }
}
