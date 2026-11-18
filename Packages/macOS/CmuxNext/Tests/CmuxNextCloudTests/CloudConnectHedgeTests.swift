@testable import CmuxNextCloud
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// ``CloudConnectHedge`` with injected attempts on a ``ManualClock``: which attempt starts when, and
/// which one answers. A black-holed connection is an attempt that never answers until cancelled.
struct CloudConnectHedgeTests {
    /// Attempt numbers in the order they started.
    actor Starts {
        private(set) var all: [Int] = []
        func add(_ n: Int) { all.append(n) }
    }

    /// An attempt that never answers (a SYN that goes nowhere) until its task is cancelled: asleep
    /// on a clock of its own that nothing advances.
    static func blackHole() async throws -> Int {
        try await ManualClock().sleep(for: .seconds(3_600))
        throw URLError(.timedOut)
    }

    @Test func readsAreHedgedKeyedOpsRetriedOnceAndOtherPostsSentOnce() {
        let keyed = Data(#"{"op":"feed.answer","idempotency_key":"approve:r1"}"#.utf8)
        let plain = Data(#"{"op":"x"}"#.utf8)
        #expect(CloudConnectHedge.replay(path: "/v1/read", body: plain) == .hedge)
        #expect(CloudConnectHedge.replay(path: "v1/auth/challenge", body: plain) == .hedge)
        #expect(CloudConnectHedge.replay(path: "/v1/ops", body: keyed) == .retryOnce)
        #expect(CloudConnectHedge.replay(path: "/v1/ops", body: Data(#"{"idempotency_key":""}"#.utf8)) == .never)
        #expect(CloudConnectHedge.replay(path: "/v1/auth/token", body: plain) == .never)
        #expect(CloudConnectHedge.replay(path: "/v1/ops", body: nil) == .never)
        var get = URLRequest(url: URL(string: "https://api.invalid/v1/auth/whoami")!)
        get.httpMethod = "GET"
        #expect(CloudConnectHedge.replay(of: get) == .hedge)
    }

    @Test func aFirstAttemptThatAnswersIsTheOnlyOne() async throws {
        let starts = Starts()
        let value = try await CloudConnectHedge().race(clock: ManualClock()) { n in
            await starts.add(n)
            return n
        }
        #expect(value == 0)
        #expect(await starts.all == [0])
    }

    @Test func aBlackHoledFirstAttemptIsOvertakenAfterTheStagger() async throws {
        let clock = ManualClock()
        let (started, starting) = AsyncStream<Int>.makeStream()
        let raced = Task {
            try await CloudConnectHedge(stagger: .seconds(1)).race(clock: clock) { n in
                starting.yield(n)
                if n == 0 { return try await Self.blackHole() }
                return n
            }
        }
        var starts = started.makeAsyncIterator()
        #expect(await starts.next() == 0)
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(1))
        #expect(await starts.next() == 1, "a new attempt once the stagger passed")
        #expect(try await raced.value == 1)
        starting.finish()
        #expect(await starts.next() == nil, "no third attempt")
    }

    @Test func noMoreThanMaxAttemptsStartWhenNoneAnswers() async throws {
        let clock = ManualClock()
        let (started, starting) = AsyncStream<Int>.makeStream()
        let raced = Task {
            try await CloudConnectHedge(stagger: .seconds(1), maxAttempts: 3).race(clock: clock) { n in
                starting.yield(n)
                return try await Self.blackHole()
            }
        }
        var starts = started.makeAsyncIterator()
        #expect(await starts.next() == 0)
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(1))
        #expect(await starts.next() == 1)
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(1))
        #expect(await starts.next() == 2)
        // The third attempt sets no timer: nothing more will start.
        #expect(clock.sleeperCount == 0)
        raced.cancel()
        await #expect(throws: (any Error).self) { try await raced.value }
        starting.finish()
        #expect(await starts.next() == nil)
    }

    @Test func aFastFailureStartsTheNextAttemptAtOnceAndTheLastFailureIsThrown() async throws {
        let starts = Starts()
        await #expect(throws: URLError(.cannotConnectToHost)) {
            try await CloudConnectHedge(stagger: .seconds(1), maxAttempts: 3).race(clock: ManualClock()) { n -> Int in
                await starts.add(n)
                throw URLError(n == 2 ? .cannotConnectToHost : .networkConnectionLost)
            }
        }
        #expect(await starts.all == [0, 1, 2], "no stagger waited: the clock never moved")
    }

    @Test func aKeyedOpIsSentOnceMoreOnlyAfterAConnectionFailure() async throws {
        let hedge = CloudConnectHedge()
        let lost = Starts()
        let value = try await hedge.send(replay: .retryOnce, clock: ManualClock()) { n in
            await lost.add(n)
            if n == 0 { throw URLError(.networkConnectionLost) }
            return n
        }
        #expect(value == 1)
        #expect(await lost.all == [0, 1])

        let refused = Starts()
        await #expect(throws: URLError(.badServerResponse)) {
            try await hedge.send(replay: .retryOnce, clock: ManualClock()) { n -> Int in
                await refused.add(n)
                throw URLError(.badServerResponse)
            }
        }
        #expect(await refused.all == [0], "not a connection failure: the op may have run")
    }

    @Test func anUnkeyedMutationIsSentOnce() async throws {
        let starts = Starts()
        await #expect(throws: URLError(.timedOut)) {
            try await CloudConnectHedge().send(replay: .never, clock: ManualClock()) { n -> Int in
                await starts.add(n)
                throw URLError(.timedOut)
            }
        }
        #expect(await starts.all == [0])
    }
}
