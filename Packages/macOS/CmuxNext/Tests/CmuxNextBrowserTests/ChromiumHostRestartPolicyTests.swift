#if DEBUG
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
@testable import CmuxNextBrowser
import CmuxNextWakeupsTestSupport
import Darwin
import Foundation
import Testing

/// Chrome's GPU process crash budget for the Chromium Host on a clock the test moves
/// (`GpuProcessHost::RecordProcessCrash`, content/browser/gpu/gpu_process_host.cc).
@Suite struct ChromiumHostRestartPolicyTests {
    static let crash = ChromiumHostExit(signal: SIGSEGV, status: nil)

    /// Crashes `policy` at each minute of `minutes` (from the clock's start) and returns each decision.
    private func crashes(at minutes: [Int], clock: ManualClock,
                         policy: inout ChromiumHostRestartPolicy) -> [ChromiumHostRestartPolicy.Decision] {
        minutes.map { minute in
            clock.advance(by: .seconds(minute * 60) - clock.now.offset)
            return policy.hostEnded(Self.crash, saidHello: true, cause: .crash)
        }
    }

    @Test func threeCrashesInFourMinutesEndTheHost() {
        let clock = ManualClock()
        var policy = ChromiumHostRestartPolicy(clock: clock)
        #expect(crashes(at: [0, 2, 4], clock: clock, policy: &policy) == [.restart, .restart, .ended(crashes: 3)])
    }

    @Test func crashesFiveMinutesApartKeepRestarting() {
        let clock = ManualClock()
        var policy = ChromiumHostRestartPolicy(clock: clock)
        #expect(crashes(at: [0, 6, 12], clock: clock, policy: &policy) == [.restart, .restart, .restart])
        #expect(policy.recentCrashes == 1)
    }

    @Test func eachFiveMinutesForgiveOneCrash() {
        let clock = ManualClock()
        var policy = ChromiumHostRestartPolicy(clock: clock)
        // 2 recent crashes; 5 minutes later one is forgiven, so the next one makes 2, not 3.
        #expect(crashes(at: [0, 1, 6], clock: clock, policy: &policy) == [.restart, .restart, .restart])
        #expect(policy.recentCrashes == 2)
        // Just under 5 minutes forgive nothing: 3.
        clock.advance(by: .seconds(4 * 60 + 59))
        #expect(policy.hostEnded(Self.crash, saidHello: true, cause: .crash) == .ended(crashes: 3))
    }

    @Test(arguments: [ChromiumHostEndCause.quit, .logout, .update])
    func anEndOfCmuxsOwnSpendsNothing(cause: ChromiumHostEndCause) {
        let clock = ManualClock()
        var policy = ChromiumHostRestartPolicy(clock: clock)
        for _ in 0..<5 {
            #expect(policy.hostEnded(Self.crash, saidHello: true, cause: cause) == .notCounted)
        }
        // A death before hello during the quit is the quit's too.
        #expect(policy.hostEnded(Self.crash, saidHello: false, cause: cause) == .notCounted)
        #expect(policy.recentCrashes == 0)
        #expect(policy.hostEnded(Self.crash, saidHello: true, cause: .crash) == .restart)
    }

    @Test func aDeathBeforeHelloCannotStartAtOnce() {
        let clock = ManualClock()
        var policy = ChromiumHostRestartPolicy(clock: clock)
        let killed = ChromiumHostExit(signal: SIGKILL, status: nil)
        let decision = policy.hostEnded(killed, saidHello: false, cause: .crash)
        #expect(decision == .cannotStart(ChromiumHostCannotStart(exit: killed)))
        // No retry: nothing is counted, and the owner starts no host.
        #expect(policy.recentCrashes == 0)
        guard case .cannotStart(let failure) = decision else { return }
        #expect(failure.description == "could not start (signal \(SIGKILL)): it ended before Chromium started")
    }

    @Test(arguments: [Int32(64), 65, 66, 67])
    func aStartFailureExitCannotStartEvenAfterHello(status: Int32) throws {
        var policy = ChromiumHostRestartPolicy(clock: ManualClock())
        let exit = ChromiumHostExit(signal: nil, status: status)
        let decision = policy.hostEnded(exit, saidHello: true, cause: .crash)
        guard case .cannotStart(let failure) = decision else {
            Issue.record("expected cannotStart, got \(decision)")
            return
        }
        let reason = try #require(ChromiumHostExit.startFailures[status])
        #expect(failure.description == "could not start (exit \(status)): \(reason)")
    }

    /// A stand-in checker with a fixed verdict (ChromiumHostSessionTests).
    nonisolated final class Checker: ChromiumHostSignatureChecking, Sendable {
        let result: ChromiumHostSignatureCheck
        init(_ result: ChromiumHostSignatureCheck) { self.result = result }
        func check(_ executable: URL) -> ChromiumHostSignatureCheck { result }
    }

    @Test func theCannotStartReasonNamesTheCodeSignatureCheck() {
        var policy = ChromiumHostRestartPolicy(clock: ManualClock())
        let killed = ChromiumHostExit(signal: SIGKILL, status: nil)
        #expect(ChromiumHostRestartPolicy.cannotStart(killed, saidHello: false, cause: .crash))
        #expect(!ChromiumHostRestartPolicy.cannotStart(killed, saidHello: true, cause: .crash))
        #expect(!ChromiumHostRestartPolicy.cannotStart(killed, saidHello: false, cause: .quit))
        let valid = policy.hostEnded(killed, saidHello: false, cause: .crash, signature: .valid)
        #expect(valid == .cannotStart(ChromiumHostCannotStart(exit: killed, signature: .valid)))
        guard case .cannotStart(let checked) = valid else { return }
        #expect(checked.description
            == "could not start (signal \(SIGKILL)): it ended before Chromium started; code signature valid")
        #expect(ChromiumHostCannotStart(exit: killed, signature: .invalid(-67_061)).description
            == "could not start (signal \(SIGKILL)): it ended before Chromium started; code signature invalid (OSStatus -67061)")
    }

    @Test func aMissingExecutableHasNoValidSignature() {
        let check = SecCodeChromiumHostSignatureChecker().check(URL(filePath: "/nonexistent/cmux Chromium Host"))
        #expect(check != .valid)
        #expect(check != .notChecked)
    }
}
#endif
