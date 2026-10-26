import Testing
@testable import CmuxNextBrowserAutomation

/// CallDeadline over FirstOutcome (p10-stability-088): a driver call answers by its deadline when
/// WebKit never calls back, and with WebKit's answer when it comes first.
@Suite(.timeLimit(.minutes(1))) struct CallDeadlineTests {
    @Test func theAnswerWinsBeforeTheDeadline() async throws {
        let value = try await CallDeadline.run(.seconds(30), what: "evaluate") { .string("done") }
        #expect(value == .string("done"))
    }

    @Test func noDeadlineWaitsForTheAnswer() async throws {
        let value = try await CallDeadline.run(nil, what: "evaluate") { .number(1) }
        #expect(value == .number(1))
    }

    @Test func aCallWithNoAnswerTimesOut() async throws {
        let (never, release) = AsyncStream.makeStream(of: Void.self)
        defer { release.finish() }
        do {
            _ = try await CallDeadline.run(.milliseconds(20), what: "evaluate") {
                for await _ in never {}
                return .null
            }
            Issue.record("the call answered without WebKit")
        } catch {
            #expect(error.code == .timeout)
        }
    }
}
