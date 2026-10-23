@testable import CmuxNextControl
import CmuxNextSettings
import CmuxNextCompat
import Foundation
import Testing

/// Two agents on one tab (#24413): any agent may drive any browser tab, and
/// cmux coordinates instead of racing. The first agent that writes to a tab
/// holds it; another agent's write answers `lease_held` naming the holder;
/// reads never lock; `browser.page.right` `release` frees the tab.
@Suite(.timeLimit(.minutes(1))) struct BrowserPageLeaseTests {
    struct NoEngine: BrowserPageEngine {
        func run(_ operation: BrowserPageOperation, tabID: String, url: String?) async throws -> JSONValue { [:] }
    }

    final class Clock: Sendable {
        let base = ContinuousClock.now
        let offset = Mutex(Duration.zero)
        var now: ContinuousClock.Instant { base + offset.withLock { $0 } }
        func advance(_ by: Duration) { offset.withLock { $0 += by } }
    }

    func install(clock: Clock = Clock()) -> ControlRouter {
        let router = ControlRouter(identity: testIdentity(), executor: BrowserPageRightTests.OpeningExecutor())
        let leases = BrowserTabLeases(now: { clock.now })
        BrowserPageService(engine: NoEngine(), leases: leases).install(on: router)
        router.snapshots.publish { $0 = BrowserPageRightTests.homeSnapshot() }
        return router
    }

    func call(_ router: ControlRouter, _ method: String, _ params: [String: JSONValue]) async -> Result<JSONValue, ControlError> {
        var params = params
        params["tab"] = params["tab"] ?? "tab_user"
        return await router.handle(ControlRequest(method: method, params: params))
    }

    @Test func aSecondAgentGetsTheHoldersNameInsteadOfRacing() async throws {
        let router = install()
        _ = try await call(router, "browser.page.fill", ["agent": "Muse", "selector": "#q", "text": "a"]).get()
        let refused = await call(router, "browser.page.fill", ["agent": "Chief", "selector": "#q", "text": "b"])
        #expect(refused.failure?.code == "lease_held")
        #expect(refused.failure?.data?["holder"] == "Muse")
        #expect(refused.failure?.data?["tab"] == "tab_user")
        // The holder keeps going.
        #expect(try await call(router, "browser.page.eval", ["agent": "Muse", "script": "1"]).get()["tab"] == "tab_user")
    }

    @Test(arguments: ["browser.page.snapshot", "browser.page.state", "browser.page.text"])
    func readsNeverLockATab(verb: String) async throws {
        let router = install()
        _ = try await call(router, "browser.page.eval", ["agent": "Muse", "script": "1"]).get()
        var params: [String: JSONValue] = ["agent": "Chief"]
        if verb == "browser.page.text" { params["selector"] = "body" }
        _ = try await call(router, verb, params).get()
        // A read takes no lease either: the first writer still gets the tab.
        let router2 = install()
        _ = try await call(router2, verb, ["agent": "Chief", "selector": "body"]).get()
        _ = try await call(router2, "browser.page.eval", ["agent": "Muse", "script": "1"]).get()
    }

    @Test func aLeaseLapsesAfterTheHolderStops() async throws {
        let clock = Clock()
        let router = install(clock: clock)
        _ = try await call(router, "browser.page.eval", ["agent": "Muse", "script": "1"]).get()
        clock.advance(.seconds(91)) // past the 90 s direct-verb lease
        #expect(try await call(router, "browser.page.eval", ["agent": "Chief", "script": "1"]).get()["tab"] == "tab_user")
    }

    @Test func releaseHandsTheTabOver() async throws {
        let router = install()
        _ = try await call(router, "browser.page.eval", ["agent": "Muse", "script": "1"]).get()
        let released = try await router.handle(ControlRequest(method: "browser.page.right",
                                                              params: ["agent": "Muse", "release": true])).get()
        #expect(released["released"] == ["tab_user"])
        #expect(try await call(router, "browser.page.eval", ["agent": "Chief", "script": "1"]).get()["tab"] == "tab_user")
    }

    @Test func aCallWithoutAnAgentNameIsLeaseFree() async throws {
        // An unnamed caller (the person's script, an older CLI) is not an
        // agent the lease can name: it runs as before.
        let router = install()
        _ = try await call(router, "browser.page.eval", ["agent": "Muse", "script": "1"]).get()
        #expect(try await call(router, "browser.page.eval", ["script": "1"]).get()["tab"] == "tab_user")
    }

    @Test func stateNamesTheDriver() async throws {
        let router = install()
        _ = try await call(router, "browser.page.eval", ["agent": "Muse", "script": "1"]).get()
        let state = try await call(router, "browser.page.state", [:]).get()
        #expect(state["driver"] == "Muse")
    }
}
