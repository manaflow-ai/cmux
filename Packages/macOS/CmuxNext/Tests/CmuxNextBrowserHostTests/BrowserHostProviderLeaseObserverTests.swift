import CmuxNextBrowserHost
import Foundation
import Testing

/// Lease frames fan out to every registered consumer (the agent cursor and the
/// lease badge); there is no single settable closure a second owner could
/// overwrite.
@MainActor
@Suite struct BrowserHostProviderLeaseObserverTests {
    private func leased(_ h: ProviderHarness) async -> FakeHost {
        let (host, _) = await h.connected()
        _ = await host.next() // tab.access
        host.ack()
        return host
    }

    @Test func everyConsumerHearsEveryLeaseChangeUntilItCancels() async throws {
        let h = ProviderHarness(tabs: [tab("c1", .cef)])
        var first: [String?] = []
        var second: [String?] = []
        let a = h.provider.observeLeases { _, lease in first.append(lease?.session) }
        let b = h.provider.observeLeases { _, lease in second.append(lease?.session) }
        let host = await leased(h)
        let lease = ProviderLease(session: "s1", actor: "agent", origin: "cli", label: "Fix", sinceMs: 1)
        host.send(.lease(targetID: "c1", lease: lease))
        host.send(.call(id: 1, method: "tabs.list", params: .object([:])))
        _ = await host.next()
        b.cancel()
        host.send(.lease(targetID: "c1", lease: nil))
        host.send(.call(id: 2, method: "tabs.list", params: .object([:])))
        _ = await host.next()
        #expect(first == ["s1", nil])
        #expect(second == ["s1"], "a cancelled consumer hears nothing more")
        _ = a
    }

    @Test func aClosedTabClearsItsLeaseForEveryConsumer() async throws {
        let h = ProviderHarness(tabs: [tab("c1", .cef)])
        var changes: [(String, String?)] = []
        let observation = h.provider.observeLeases { target, lease in changes.append((target, lease?.session)) }
        let host = await leased(h)
        host.send(.lease(targetID: "c1", lease: ProviderLease(session: "s1", actor: "agent", origin: "cli", label: "Fix", sinceMs: 1)))
        host.send(.call(id: 1, method: "tabs.list", params: .object([:])))
        _ = await host.next()
        h.tabs.providerTabs = []
        #expect(await host.next() == .event(name: "tab.gone", payload: .object(["targetId": .string("c1")])))
        #expect(changes.count == 2)
        #expect(changes.last?.0 == "c1" && changes.last?.1 == nil, "tab gone is a lease end")
        _ = observation
    }
}
