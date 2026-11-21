import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The lookup's `_acpmux/status` keeps every call it made and takes the first answer
/// (``AcpmuxHost/lookupStatus(socketPath:attempts:call:)``). Before, each call ended at its time and
/// the next one started over: on Leo's NIGHTLY (2026-11-21) a daemon that answered in about 10 s cost
/// 5 + 10 + 20 + 10 s, 46 s from the lookup to the pane's transport.
struct AcpmuxLookupStatusHedgeTests {
    private nonisolated final class Calls: @unchecked Sendable {  // the lock guards `count`
        private let lock = NSLock()
        private var count = 0
        var made: Int { lock.withLock { count } }
        func next() -> Int { lock.withLock { count += 1; return count } }
    }

    private nonisolated static let answer = AcpmuxStatus(["pid": 7])

    /// A slow first call is not given up when the next one joins: its answer wins.
    @Test func aSlowFirstCallStillAnswers() async throws {
        let calls = Calls()
        let start = ContinuousClock.now
        let status = try await AcpmuxHost.lookupStatus(
            socketPath: "/s", attempts: [.milliseconds(50), .milliseconds(50)],
            call: { _ in
                let n = calls.next()
                // The first call answers at 300 ms; any later one never does (cancelled).
                try await Task.sleep(for: n == 1 ? .milliseconds(300) : .seconds(60))
                return Self.answer
            })
        #expect(status == Self.answer)
        #expect(calls.made == 3)
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    /// A call on a connection nothing answers (made just before a restart) is joined by another,
    /// whose answer ends both.
    @Test func aHungFirstCallIsOvertaken() async throws {
        let calls = Calls()
        let start = ContinuousClock.now
        let status = try await AcpmuxHost.lookupStatus(
            socketPath: "/s", attempts: [.milliseconds(50), .seconds(60)],
            call: { _ in
                if calls.next() == 1 { try await Task.sleep(for: .seconds(60)) }
                return Self.answer
            })
        #expect(status == Self.answer)
        #expect(calls.made == 2)
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    /// A daemon that answers at once is asked once.
    @Test func aPromptAnswerIsOneCall() async throws {
        let calls = Calls()
        _ = try await AcpmuxHost.lookupStatus(socketPath: "/s", attempts: [.milliseconds(50)],
                                              call: { _ in _ = calls.next(); return Self.answer })
        #expect(calls.made == 1)
    }
}
