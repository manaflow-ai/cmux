import CmuxNextBrowser
import CmuxNextWakeups
import Dispatch
import Testing

/// SystemHostLookup runs getaddrinfo on the BackgroundWork system lane, never on the cooperative pool.
@Suite(.timeLimit(.minutes(1))) struct SystemHostLookupTests {
    @Test func aLookupResolvesThroughTheSystemLane() async {
        let lookup = SystemHostLookup(work: BackgroundWork(label: "test.dns"))
        #expect(await lookup.resolves("localhost"))
    }

    @Test func aLookupThatCannotStartDoesNotHoldItsCaller() async {
        let work = BackgroundWork(label: "test.dns.full")
        let release = DispatchSemaphore(value: 0)
        let (started, report) = AsyncStream.makeStream(of: Void.self)
        // Every system slot holds a hung call (a resolver that never answers).
        for _ in 0..<BackgroundWork.systemWidth {
            work.post(.userBlocking, mayBlock: .system) {
                report.yield()
                release.wait()
            }
        }
        var waiting = BackgroundWork.systemWidth
        for await _ in started {
            waiting -= 1
            if waiting == 0 { break }
        }
        // The caller's deadline cancels it: it returns false at once, and the lookup never runs later.
        let lookup = SystemHostLookup(work: work)
        let task = Task { await lookup.resolves("localhost") }
        task.cancel()
        #expect(await task.value == false)
        for _ in 0..<BackgroundWork.systemWidth { release.signal() }
    }
}
