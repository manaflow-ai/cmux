import Foundation
import Testing

@testable import CmuxBrowser

/// Domain policy updates reach WebKit as content-rule compilations on the
/// main actor. An agent can set the policy far faster than WebKit compiles
/// it, so the driver applies policies through a runner that keeps only the
/// newest one waiting: superseded policies are never compiled.
@MainActor
@Suite("Browser REPL latest-value runner")
struct BrowserReplLatestValueRunnerTests {
    @Test("Values submitted while one is applied are coalesced: only the newest is applied next")
    func supersededValuesAreSkipped() async {
        let applied = BrowserReplAppliedValues()
        let runner = BrowserReplLatestValueRunner<Int> { value in
            await applied.apply(value)
        }
        runner.submit(1)
        await applied.waitUntilStarted(1)
        for value in 2...100 { runner.submit(value) }
        applied.release()
        await runner.idle()
        #expect(applied.values == [1, 100])

        // An idle runner applies the next value at once.
        runner.submit(101)
        await runner.idle()
        #expect(applied.values == [1, 100, 101])
    }
}

/// Records applied values; the first apply waits until `release()`.
@MainActor
final class BrowserReplAppliedValues {
    private(set) var values: [Int] = []
    private var released = false
    private var gate: CheckedContinuation<Void, Never>?
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func apply(_ value: Int) async {
        values.append(value)
        for (index, waiter) in startWaiters.enumerated().reversed() where waiter.0 <= values.count {
            startWaiters.remove(at: index)
            waiter.1.resume()
        }
        if !released { await withCheckedContinuation { gate = $0 } }
    }

    func waitUntilStarted(_ count: Int) async {
        guard values.count < count else { return }
        await withCheckedContinuation { startWaiters.append((count, $0)) }
    }

    func release() {
        released = true
        gate?.resume()
        gate = nil
    }
}
