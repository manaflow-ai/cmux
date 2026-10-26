@testable import CmuxNextApp
import CmuxNextBrowser
@testable import CmuxNextRemoteLocalhost
@testable import CmuxNextRemoteLocalhostService
import Foundation
import CmuxNextCompat
import Testing

/// A tab on a Cloud machine's port (`cmux cloud open-browser`) failed every request once the
/// machine's link dropped or was replaced, and came back blank after a relaunch (#25595): its store
/// kept the first `cloud.browser.open` route for good, and a restored tab had none. The route now
/// asks for the machine's route again when it has none or when the one it has is gone.
struct CloudBrowserRouteTests {
    private nonisolated struct Tunnel: LoopbackTunnel {
        let route: UInt16
        var events: AsyncStream<LoopbackTunnelEvent> { AsyncStream { $0.finish() } }
        func write(_ data: Data) async throws {}
        func consumed(_ count: Int) {}
        func shutdownWrite() {}
        func close() {}
    }

    /// Opens through the route numbered by its proxy port; fails as `dead` says for that port.
    private nonisolated struct Opener: LoopbackTunnelOpening {
        let port: UInt16
        let dead: @Sendable (UInt16) -> LoopbackTunnelFailure?
        func openTunnel(host: String, port target: UInt16) async throws(LoopbackTunnelFailure) -> any LoopbackTunnel {
            if let failure = dead(port) { throw failure }
            return Tunnel(route: port)
        }
    }

    private nonisolated final class Fetches: Sendable {
        let count = Mutex(0)
        let answers: [UInt16]
        init(_ answers: [UInt16]) { self.answers = answers }
        func next() throws -> CloudBrowserRoute.Answer {
            let index = count.withLock { count in defer { count += 1 }; return count }
            guard index < answers.count else { throw LoopbackTunnelFailure.unavailable("no route") }
            return .init(proxyPort: answers[index], credential: ProxyCredential(username: "cmux", password: String(repeating: "s", count: 32)))
        }
    }

    /// A clock the test moves.
    private nonisolated final class Now: Sendable {
        let start = ContinuousClock.now
        let offset = Mutex(Duration.zero)
        var instant: ContinuousClock.Instant { start.advanced(by: offset.withLock { $0 }) }
        func advance(by duration: Duration) { offset.withLock { $0 += duration } }
    }

    private func route(first: UInt16?, fetches: Fetches, now: Now = Now(),
                       dead: @escaping @Sendable (UInt16) -> LoopbackTunnelFailure?) -> CloudBrowserRoute {
        CloudBrowserRoute(
            first: first.map { .init(proxyPort: $0, credential: ProxyCredential(username: "cmux", password: String(repeating: "s", count: 32))) },
            fetch: { _, _ in try fetches.next() },
            now: { now.instant },
            makeOpener: { Opener(port: $0.proxyPort, dead: dead) })
    }

    @Test func aMachineStillDownIsNotAskedForARouteOnEveryRequest() async throws {
        let fetches = Fetches([2, 3, 4])
        let now = Now()
        // The link is down: every route the server answers fails too.
        let route = route(first: 1, fetches: fetches, now: now) { _ in .unavailable("link down") }
        _ = try? await route.openTunnel(host: "localhost", port: 3000)
        #expect(fetches.count.withLock { $0 } == 1)
        // A dev server's reload client asks again at once: no fetch inside the spacing.
        for _ in 0..<5 { _ = try? await route.openTunnel(host: "localhost", port: 3000) }
        #expect(fetches.count.withLock { $0 } == 1)
        now.advance(by: .seconds(2))
        _ = try? await route.openTunnel(host: "localhost", port: 3000)
        #expect(fetches.count.withLock { $0 } == 2)
        // The machine connected again: the next request fetches at once.
        await route.machineConnected()
        _ = try? await route.openTunnel(host: "localhost", port: 3000)
        #expect(fetches.count.withLock { $0 } == 3)
    }

    @Test func aGoneRouteIsAskedForAgainAndTheRequestGoesThroughTheNewOne() async throws {
        let fetches = Fetches([2])
        let route = route(first: 1, fetches: fetches) { $0 == 1 ? .unavailable("link replaced") : nil }
        let tunnel = try await route.openTunnel(host: "localhost", port: 3000)
        #expect((tunnel as? Tunnel)?.route == 2)
        #expect(fetches.count.withLock { $0 } == 1)
        // The new route stays: the next request fetches nothing.
        _ = try await route.openTunnel(host: "localhost", port: 3000)
        #expect(fetches.count.withLock { $0 } == 1)
    }

    @Test func aRestoredTabFetchesItsRouteOnTheFirstRequest() async throws {
        let fetches = Fetches([5])
        let route = route(first: nil, fetches: fetches) { _ in nil }
        let tunnel = try await route.openTunnel(host: "localhost", port: 5173)
        #expect((tunnel as? Tunnel)?.route == 5)
    }

    @Test func aPortThatRefusedFetchesNoRoute() async throws {
        let fetches = Fetches([2])
        let route = route(first: 1, fetches: fetches) { _ in .refused }
        await #expect(throws: LoopbackTunnelFailure.refused) { try await route.openTunnel(host: "localhost", port: 3000) }
        #expect(fetches.count.withLock { $0 } == 0)
    }

    @Test func aMachineStillDownAnswersUnavailable() async throws {
        let route = route(first: nil, fetches: Fetches([]), dead: { _ in nil })
        await #expect(throws: LoopbackTunnelFailure.unavailable("Cloud browser route unavailable")) {
            try await route.openTunnel(host: "localhost", port: 3000)
        }
    }

    @Test func concurrentRequestsShareOneFetch() async throws {
        let fetches = Fetches([2, 3])
        let route = route(first: 1, fetches: fetches) { $0 == 1 ? .unavailable("gone") : nil }
        let ports = await withTaskGroup(of: UInt16?.self) { group in
            for _ in 0..<8 { group.addTask { (try? await route.openTunnel(host: "localhost", port: 3000) as? Tunnel)?.route } }
            var ports = Set<UInt16?>()
            for await port in group { ports.insert(port) }
            return ports
        }
        #expect(ports == [2])
        #expect(fetches.count.withLock { $0 } == 1)
    }
}

/// A proxied tab restored after a relaunch was blank for good (#25595); it now gets a store whose
/// route is fetched again, and one the person took to a web page loads that page.
@MainActor
struct ProxiedBrowserTabsRestoreTests {
    private func defaults() throws -> UserDefaults {
        let name = "ProxiedBrowserTabsRestoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private let machine = ProxiedBrowserTabs.Machine(id: "vm-1", name: "build-box")
    private let store = BrowserMachineStore(machineKey: "abcdef0123456789", machineName: "build-box", proxyPort: 4100)

    @Test func aRestoredTabGetsAStoreForItsMachine() async throws {
        let defaults = try defaults()
        let before = ProxiedBrowserTabs(defaults: defaults)
        before.expect(store, machine: machine)
        before.record("tab-1", store: store)

        // Relaunch: no live store, the tab and its machine are kept.
        let after = ProxiedBrowserTabs(defaults: defaults)
        let url = URL(string: "http://localhost:3000/")
        #expect(after.plan(for: "tab-1", url: url, base: BrowserTabConfiguration()) == .blocked)
        var asked: [ProxiedBrowserTabs.Machine] = []
        let restored = BrowserMachineStore(machineKey: "abcdef0123456789", machineName: "build-box", proxyPort: 4200)
        after.restore = { asked.append($0); return restored }
        let configuration = await after.configuration(for: "tab-1", url: url, base: BrowserTabConfiguration()) { nil }
        #expect(asked == [machine])
        #expect(configuration?.machineStore == restored)
        #expect(configuration?.navigationGuard == .loopbackOnly)
    }

    @Test func aRestoredTabWithoutAStoreStaysBlank() async throws {
        let defaults = try defaults()
        let before = ProxiedBrowserTabs(defaults: defaults)
        before.expect(store, machine: machine)
        before.record("tab-1", store: store)
        let after = ProxiedBrowserTabs(defaults: defaults)
        after.restore = { _ in nil }
        let configuration = await after.configuration(for: "tab-1", url: URL(string: "http://localhost:3000/"), base: BrowserTabConfiguration()) {
            BrowserTabConfiguration()
        }
        #expect(configuration == nil)
    }

    @Test func aRestoredTabOnAWebPageLoadsItWithoutTheMachine() throws {
        let defaults = try defaults()
        let before = ProxiedBrowserTabs(defaults: defaults)
        before.expect(store, machine: machine)
        before.record("tab-1", store: store)
        let after = ProxiedBrowserTabs(defaults: defaults)
        guard case .configured(let configuration) = after.plan(for: "tab-1", url: URL(string: "https://github.com/"), base: BrowserTabConfiguration()) else {
            Issue.record("a web page of a kept tab is configured")
            return
        }
        #expect(configuration.machineStore == nil)
        #expect(configuration.navigationGuard == .noLoopback)
    }
}

/// A click resumed a paused machine: its daemon connected while its record still read paused, so a
/// stranded page's refetch was refused and the page stayed on "not connected" (#25595 re-review).
struct CloudBrowserRefetchGateTests {
    @Test(arguments: [(true, false, true), (false, true, true), (true, true, true), (false, false, false)])
    func aPageMayAskForTheRouteOfARunningOrConnectedMachineOnly(live: Bool, connected: Bool, may: Bool) {
        #expect(BrowserTabOpen.mayRefetch(live: live, connected: connected) == may)
    }
}
