@testable import CmuxNextControl
import CmuxNextCompat
import Foundation
import Testing

/// An agent at a passkey step asks the person instead of running the ceremony in a
/// background tab, where WebKit rejects it ("The document is not focused") and
/// Chromium refuses a hidden page: one banner, and the person's click brings the
/// tab forward, focused, before the trigger runs, so they only touch Touch ID
/// (plans/cmux-next/agent-browser-passkey-DESIGN.md 3.2).
@Suite(.timeLimit(.minutes(1))) struct BrowserPasskeyRequestsTests {
    /// Records what the requests ask of the app, in order.
    final class Host: BrowserPasskeyHost {
        let events = Mutex<[String]>([])
        let front = Mutex<Set<String>>([])

        @MainActor func isInFront(tabID: String) async -> Bool { front.withLock { $0.contains(tabID) } }
        @MainActor func reveal(tabID: String) async throws {
            events.withLock { $0.append("reveal \(tabID)") }
            front.withLock { _ = $0.insert(tabID) }
        }
        @MainActor func post(_ request: BrowserPasskeyRequest) async {
            events.withLock { $0.append("post \(request.tabID) \(request.agent) \(request.site)") }
        }
        @MainActor func withdraw(_ id: String) async { events.withLock { $0.append("withdraw \(id)") } }

        var log: [String] { events.withLock { $0 } }
    }

    final class TestClock: Sendable {
        let instant = Mutex(ContinuousClock.now)
        func advance(_ by: Duration) { instant.withLock { $0 += by } }
    }

    func make(_ host: Host, clock: TestClock = TestClock()) -> BrowserPasskeyRequests {
        BrowserPasskeyRequests(host: host, ttl: .seconds(300), now: { clock.instant.withLock { $0 } })
    }

    func trigger(_ host: Host, _ tab: String) -> @Sendable () async throws -> Void {
        { host.events.withLock { $0.append("trigger \(tab)") } }
    }

    @Test func aBackgroundTabAsksThePersonAndWaits() async throws {
        let host = Host()
        let requests = make(host)
        let raised = try await requests.raise(tabID: "tab_a", agent: "Chief", site: "npmjs.com", trigger: trigger(host, "tab_a"))
        #expect(raised.status == .pending)
        // A banner, and nothing moved or clicked behind the person's back.
        #expect(host.log == ["post tab_a Chief npmjs.com"])
    }

    @Test func thePersonsClickRevealsTheTabThenTriggersOnce() async throws {
        let host = Host()
        let requests = make(host)
        let raised = try await requests.raise(tabID: "tab_a", agent: "Chief", site: "npmjs.com", trigger: trigger(host, "tab_a"))
        #expect(try await requests.answer(raised.id) == .triggered)
        #expect(host.log == ["post tab_a Chief npmjs.com", "reveal tab_a", "trigger tab_a"])
        // A second click (banner and Home card both) runs nothing again.
        #expect(try await requests.answer(raised.id) == .unknown)
        #expect(host.log.count == 3)
    }

    @Test func aTabAlreadyInFrontTriggersAtOnceWithoutABanner() async throws {
        let host = Host()
        host.front.withLock { _ = $0.insert("tab_a") }
        let requests = make(host)
        let raised = try await requests.raise(tabID: "tab_a", agent: "Chief", site: "npmjs.com", trigger: trigger(host, "tab_a"))
        #expect(raised.status == .triggered)
        #expect(host.log == ["trigger tab_a"])
    }

    @Test func aNewRequestForTheSameTabReplacesTheOld() async throws {
        let host = Host()
        let requests = make(host)
        let first = try await requests.raise(tabID: "tab_a", agent: "Chief", site: "npmjs.com", trigger: trigger(host, "tab_a"))
        let second = try await requests.raise(tabID: "tab_a", agent: "Chief", site: "npmjs.com", trigger: trigger(host, "tab_a"))
        #expect(first.id != second.id)
        #expect(host.log.contains("withdraw \(first.id)"))
        #expect(try await requests.answer(first.id) == .unknown)
        #expect(try await requests.answer(second.id) == .triggered)
    }

    @Test func anOldRequestExpiresAndRunsNothing() async throws {
        let host = Host()
        let clock = TestClock()
        let requests = make(host, clock: clock)
        let raised = try await requests.raise(tabID: "tab_a", agent: "Chief", site: "npmjs.com", trigger: trigger(host, "tab_a"))
        clock.advance(.seconds(301))
        #expect(try await requests.answer(raised.id) == .expired)
        #expect(!host.log.contains("reveal tab_a"))
        #expect(!host.log.contains("trigger tab_a"))
        #expect(host.log.contains("withdraw \(raised.id)"))
    }
}
