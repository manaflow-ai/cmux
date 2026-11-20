import CmuxNextAgentPane
@testable import CmuxNextDaemonService
import CmuxUpdater
import Foundation
import Testing

@MainActor struct UpdateAgentActivityRefreshTests {
    private final class Reader {
        var time = ContinuousClock.now
        var reads = 0
        var pending: CheckedContinuation<AcpmuxSessionCensus?, Never>?
        func read() async -> AcpmuxSessionCensus? {
            reads += 1
            return await withCheckedContinuation { pending = $0 }
        }
        func answer(_ value: AcpmuxSessionCensus?) { pending?.resume(returning: value); pending = nil }
    }
    private let clear = UpdateRelaunchBlockers(busyAgentCount: 0, runningCommandCount: 0)
    private var empty: AcpmuxSessionCensus { .parse(["sessions": [[String: Any]]()]) }

    @Test func refreshKeepsFreshAnswerButExpiresItWhileReaderStalls() async throws {
        let reader = Reader()
        let activity = UpdateAgentActivity(readCensus: { await reader.read() }, now: { reader.time })
        #expect(activity.applying(to: clear).daemonStateUnavailable)
        for _ in 0..<1_000 where reader.pending == nil { await Task.yield() }
        try #require(reader.pending != nil)
        reader.answer(empty)
        for _ in 0..<1_000 where activity.census == nil { await Task.yield() }
        try #require(activity.census != nil)
        reader.time = reader.time.advanced(by: .seconds(1.1))
        #expect(!activity.applying(to: clear).daemonStateUnavailable)
        for _ in 0..<1_000 where reader.pending == nil { await Task.yield() }
        try #require(reader.pending != nil)
        #expect(reader.reads == 2)
        reader.time = reader.time.advanced(by: .seconds(1))
        #expect(activity.applying(to: clear).daemonStateUnavailable)
        #expect(activity.census == nil)
        reader.answer(nil)
        await Task.yield()
    }

    @Test func blockingAnswerBacksOffAndThenObservesWorkEnding() async throws {
        let reader = Reader()
        let activity = UpdateAgentActivity(readCensus: { await reader.read() }, now: { reader.time })
        _ = activity.applying(to: clear)
        for _ in 0..<1_000 where reader.pending == nil { await Task.yield() }
        try #require(reader.pending != nil)
        var busy = empty
        busy.inTurn = 1
        reader.answer(busy)
        for _ in 0..<1_000 where activity.census == nil { await Task.yield() }
        try #require(activity.census?.inTurn == 1)
        for _ in 0..<4 {
            reader.time = reader.time.advanced(by: .seconds(1))
            _ = activity.applying(to: clear)
            await Task.yield()
        }
        #expect(reader.reads == 1)
        reader.time = reader.time.advanced(by: .seconds(1))
        _ = activity.applying(to: clear)
        for _ in 0..<1_000 where reader.pending == nil { await Task.yield() }
        try #require(reader.pending != nil)
        reader.answer(empty)
        for _ in 0..<1_000 where activity.census?.inTurn != 0 { await Task.yield() }
        #expect(activity.census?.inTurn == 0)
        #expect(reader.reads == 2)
    }
}
