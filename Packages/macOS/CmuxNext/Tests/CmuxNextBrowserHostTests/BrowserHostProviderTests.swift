import CmuxNextBrowser
import CmuxNextBrowserAutomation
import Foundation
import Testing
@testable import CmuxNextBrowserHost

/// The provider against a fake host over a socketpair: hello, tab events,
/// tab.access, driver calls, leases, user input and reconnects.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct BrowserHostProviderTests {
    @Test func helloCarriesTheIdentitySecretAndEveryTab() async throws {
        let h = ProviderHarness(tabs: [tab("w1", .webkit, title: "Web"), tab("c1", .cef, url: "https://c.test/", visible: false)])
        let (_, hello) = await h.connected()
        guard case .hello(let version, let providerID, let installID, let secret, let engines, let tabs)? = hello else {
            Issue.record("expected hello, got \(String(describing: hello))")
            return
        }
        #expect(version == 1 && providerID == "cmux-app" && installID == "inst_1")
        #expect(secret.value == "s3cret-value")
        #expect(engines == ["webkit", "cef"])
        #expect(tabs == [
            ProviderTabAnnounce(targetID: "w1", engine: "webkit", workspace: "ws_1", profile: "default", url: "https://a.test/", title: "Web", visible: true),
            ProviderTabAnnounce(targetID: "c1", engine: "cef", workspace: "ws_1", profile: "default", url: "https://c.test/", title: "A", visible: false),
        ])
    }

    @Test func tabAccessFollowsHelloURLChangesAndExtensionChanges() async throws {
        let h = ProviderHarness(tabs: [tab("w1", .webkit), tab("c1", .cef)])
        h.access.table["c1"] = ProviderTabAccess(extensionHostAccess: true, userOverride: false, extensions: ["Pass"])
        let (host, _) = await h.connected()
        // Once after hello, for the CEF tab only.
        #expect(await host.next() == .tabAccess(targetID: "c1", extensionHostAccess: true, userOverride: false, extensions: ["Pass"]))
        host.ack()

        h.tabs.providerTabs = [tab("w1", .webkit), tab("c1", .cef, url: "https://b.test/")]
        #expect(await host.next() == .event(name: "tab.navigated", payload: .object(["targetId": .string("c1"), "url": .string("https://b.test/")])))
        #expect(await host.next() == .tabAccess(targetID: "c1", extensionHostAccess: true, userOverride: false, extensions: ["Pass"]))

        // The extension store changed: the person disabled the extension.
        h.access.table["c1"] = ProviderTabAccess(extensionHostAccess: false, userOverride: false, extensions: [])
        #expect(await host.next() == .tabAccess(targetID: "c1", extensionHostAccess: false, userOverride: false, extensions: []))

        // The person allowed agents in the tab.
        h.access.table["c1"] = ProviderTabAccess(extensionHostAccess: true, userOverride: true, extensions: ["Pass"])
        #expect(await host.next() == .tabAccess(targetID: "c1", extensionHostAccess: true, userOverride: true, extensions: ["Pass"]))
    }

    @Test func newClosedAndRetitledTabsReachTheHost() async throws {
        let h = ProviderHarness(tabs: [tab("w1", .webkit)])
        let (host, _) = await h.connected()
        host.ack()

        h.tabs.providerTabs = [tab("w1", .webkit), tab("c2", .cef)]
        #expect(await host.next() == .event(name: "tab.announced", payload: BrowserHostProvider.announcePayload(tab("c2", .cef))))
        // A new CEF tab's access follows its announce.
        #expect(await host.next() == .tabAccess(targetID: "c2", extensionHostAccess: false, userOverride: false, extensions: []))

        h.tabs.providerTabs = [tab("w1", .webkit, title: "Renamed"), tab("c2", .cef)]
        #expect(await host.next() == .event(name: "tab.announced", payload: BrowserHostProvider.announcePayload(tab("w1", .webkit, title: "Renamed"))))

        h.tabs.providerTabs = [tab("c2", .cef)]
        #expect(await host.next() == .event(name: "tab.gone", payload: .object(["targetId": .string("w1")])))
    }

    @Test func callsReachTheDriverAndAnswerInTheProtocolShape() async throws {
        let h = ProviderHarness(tabs: [tab("w1", .webkit)])
        h.driver.answer = { method, params in
            guard method == "tab.info" else { return .failure(DriverError(.evaluation, "boom", errorName: "TypeError")) }
            return .success(.object(["url": .string("https://a.test/"), "echo": params]))
        }
        let (host, _) = await h.connected()
        host.ack()
        let params = DriverJSON.object(["targetId": .string("w1")])
        host.send(.call(id: 41, method: "tab.info", params: params))
        #expect(await host.next() == .result(id: 41, result: .object(["url": .string("https://a.test/"), "echo": params]), error: nil))
        #expect(h.marking.marked == ["w1"])

        host.send(.call(id: 42, method: "frame.evaluate", params: params))
        #expect(await host.next() == .result(id: 42, result: nil, error: .object([
            "code": .string("evaluation"), "message": .string("boom"), "errorName": .string("TypeError"),
        ])))
        // The first call per tab marks it; later ones do not repeat.
        #expect(h.marking.marked == ["w1"])

        h.driver.emitter.yield(DriverEvent(name: "dialog.opened", payload: .object(["targetId": .string("w1")])))
        #expect(await host.next() == .event(name: "dialog.opened", payload: .object(["targetId": .string("w1")])))
    }

    @Test func tabLessCallsAreRefusedByTheAppItself() async throws {
        let h = ProviderHarness(tabs: [tab("w1", .webkit)])
        var called: [String] = []
        h.driver.answer = { method, _ in
            called.append(method)
            return .success(.array([]))
        }
        let (host, _) = await h.connected()
        host.ack()
        host.send(.call(id: 1, method: "cookies.get", params: .object(["urls": .array([])])))
        guard case .result(1, nil, .object(let error)?)? = await host.next() else {
            Issue.record("expected an error result")
            return
        }
        #expect(error["code"] == .string("unsupported"))
        host.send(.call(id: 2, method: "tab.info", params: .object(["targetId": .number(3)])))
        guard case .result(2, nil, .object(let second)?)? = await host.next() else {
            Issue.record("expected an error result")
            return
        }
        #expect(second["code"] == .string("unsupported"))
        // tabs.list and tabs.open name no tab and still reach the driver.
        host.send(.call(id: 3, method: "tabs.list", params: .object([:])))
        #expect(await host.next() == .result(id: 3, result: .array([]), error: nil))
        #expect(called == ["tabs.list"])
    }

    @Test func leasesReachTheAppAndMarkTheTabAndUserInputIsReported() async throws {
        let h = ProviderHarness(tabs: [tab("c1", .cef)])
        var changes: [(String, ProviderLease?)] = []
        h.provider.onLeaseChange = { changes.append(($0, $1)) }
        let (host, _) = await h.connected()
        _ = await host.next() // tab.access
        host.ack()

        // No lease: a person's input is not reported.
        #expect(!h.provider.reportUserInput(event: BrowserHostProviderReviewTests.key(.keyDown), targetID: "c1"))
        let lease = ProviderLease(session: "s1", actor: "agent", origin: "cli", label: "Fix", sinceMs: 1)
        host.send(.lease(targetID: "c1", lease: lease))
        host.send(.call(id: 1, method: "tabs.list", params: .object([:])))
        _ = await host.next() // the call's result: the lease frame ran before it
        #expect(h.provider.leases["c1"] == lease)
        #expect(h.marking.marked == ["c1"])
        #expect(changes.count == 1 && changes[0].0 == "c1" && changes[0].1 == lease)

        #expect(h.provider.reportUserInput(event: BrowserHostProviderReviewTests.key(.keyDown), targetID: "c1"))
        #expect(await host.next() == .userInput(targetID: "c1"))

        host.send(.lease(targetID: "c1", lease: nil))
        host.send(.call(id: 2, method: "tabs.list", params: .object([:])))
        _ = await host.next()
        #expect(h.provider.leases["c1"] == nil)
        #expect(changes.count == 2 && changes[1].1 == nil)
    }

    @Test func aHostThatClosesBeforeTheAckIsRetriedAfterBackoff() async throws {
        let h = ProviderHarness()
        let (host, _) = await h.connected()
        host.link.close()
        await h.clock.sleepers(atLeast: 1)
        #expect(h.provider.status == .waitingToRetry)
        #expect(h.dialer.count == 1)
        h.clock.advance(by: .seconds(1))
        let second = await h.nextHost()
        guard case .hello? = await second?.next() else {
            Issue.record("expected a second hello")
            return
        }
        #expect(h.dialer.count == 2)
    }

    @Test func aListenerThatIsNotTheHostNeverGetsTheSecret() async throws {
        let h = ProviderHarness()
        // The daemon started the host as another process: our socket peer is not it.
        h.credentials.value = ProviderCredentials(socketPath: "/unused", secret: ProviderSecret("s3cret-value"), hostPID: getpid() + 1)
        h.provider.start()
        let host = try #require(await h.nextHost())
        // Closed before any byte: no hello, so no secret.
        #expect(await host.next() == nil)
        await h.clock.sleepers(atLeast: 1)
        #expect(h.provider.status == .waitingToRetry)
    }

    @Test func aFirstFrameOtherThanTheAckDropsTheLink() async throws {
        let h = ProviderHarness()
        let (host, _) = await h.connected()
        host.send(.call(id: 1, method: "tabs.list", params: .null))
        // The provider closes; the host sees the end of the stream.
        #expect(await host.next() == nil)
        await h.clock.sleepers(atLeast: 1)
        #expect(h.provider.status == .waitingToRetry)
    }

    @Test func newCredentialsReconnectAtOnceAndNoCredentialsStayIdle() async throws {
        let h = ProviderHarness()
        h.credentials.value = nil
        h.provider.start()
        // Nothing to dial: idle, no timer, no dial.
        h.provider.credentialsChanged()
        h.credentials.value = ProviderCredentials(socketPath: "/next", secret: ProviderSecret("new-secret"), hostPID: getpid())
        h.provider.credentialsChanged()
        let host = await h.nextHost()
        guard case .hello(_, _, _, let secret, _, _)? = await host?.next() else {
            Issue.record("expected hello")
            return
        }
        #expect(secret.value == "new-secret")
        #expect(h.dialer.count == 1)

        // A dropped link with fresh credentials reconnects without waiting for backoff.
        host?.link.close()
        await h.clock.sleepers(atLeast: 1)
        h.provider.credentialsChanged()
        let again = await h.nextHost()
        guard case .hello? = await again?.next() else {
            Issue.record("expected a reconnect hello")
            return
        }
    }
}
