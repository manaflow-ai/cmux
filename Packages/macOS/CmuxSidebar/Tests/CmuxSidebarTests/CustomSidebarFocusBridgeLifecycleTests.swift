import AppKit
import CmuxFoundation
import Foundation
import Testing
import WebKit

@testable import CmuxSidebar

@Suite("CustomSidebarWebView focus bridge lifecycle")
@MainActor
struct CustomSidebarFocusBridgeLifecycleTests {
    private struct RemoteFixtures {
        let loopbackServer: LoopbackHTTPServer
        let otherLoopbackServer: LoopbackHTTPServer
        let publicServer: LoopbackHTTPServer
        let loopbackOrigin: URL
        let otherLoopbackOrigin: URL
        let publicOrigin: URL

        var loopback: CustomSidebarWebSource { .remote(loopbackOrigin) }
        var otherLoopback: CustomSidebarWebSource { .remote(otherLoopbackOrigin) }
        var publicPage: CustomSidebarWebSource { .remote(publicOrigin) }

        func stop() {
            loopbackServer.stop()
            otherLoopbackServer.stop()
            publicServer.stop()
        }
    }

    private struct Harness {
        let coordinator: CustomSidebarWebView.Coordinator
        let webView: WKWebView
        let container: CustomSidebarWebContainerView
        let registry: CustomSidebarFocusHandlerRegistrySpy
    }

    private func makeFixtures() throws -> RemoteFixtures {
        let (loopbackServer, loopbackOrigin) = try LoopbackHTTPServer.started(
            body: "<!doctype html><title>loopback</title>"
        )
        do {
            let (otherLoopbackServer, otherLoopbackOrigin) = try LoopbackHTTPServer.started(
                body: "<!doctype html><title>other loopback</title>"
            )
            do {
                let (publicServer, publicLoopbackOrigin) = try LoopbackHTTPServer.started(
                    body: "<!doctype html><title>unqualified</title>"
                )
                do {
                    var components = try #require(
                        URLComponents(url: publicLoopbackOrigin, resolvingAgainstBaseURL: false)
                    )
                    components.host = "localhost"
                    return RemoteFixtures(
                        loopbackServer: loopbackServer,
                        otherLoopbackServer: otherLoopbackServer,
                        publicServer: publicServer,
                        loopbackOrigin: loopbackOrigin,
                        otherLoopbackOrigin: otherLoopbackOrigin,
                        publicOrigin: try #require(components.url)
                    )
                } catch {
                    publicServer.stop()
                    throw error
                }
            } catch {
                otherLoopbackServer.stop()
                throw error
            }
        } catch {
            loopbackServer.stop()
            throw error
        }
    }

    private func makeHarness() -> Harness {
        let webView = WKWebView(frame: .zero)
        let container = CustomSidebarWebContainerView(webView: webView)
        let coordinator = CustomSidebarWebView.Coordinator()
        coordinator.container = container
        let registry = CustomSidebarFocusHandlerRegistrySpy()
        coordinator.attach(registry: registry, webView: webView)
        return Harness(coordinator: coordinator, webView: webView, container: container, registry: registry)
    }

    private func focusing(
        _ status: CustomSidebarFocusStatus
    ) -> @MainActor (UUID) -> CustomSidebarFocusStatus {
        { _ in status }
    }

    @Test("a loopback source registers the handler and locks the frame")
    func loopbackSourceArms() throws {
        let fixtures = try makeFixtures()
        defer { fixtures.stop() }
        let h = makeHarness()

        h.coordinator.apply(source: fixtures.loopback, focusWorkspace: focusing(.focused), into: h.webView)

        #expect(h.registry.installed != nil)
        #expect(h.coordinator.armedScope != nil)
        #expect(h.webView.navigationDelegate is CustomSidebarNavigationLock)
    }

    // The strongest form of "no" for an unqualified page: the handler is never registered, so
    // `window.webkit.messageHandlers.cmuxSidebarFocusWorkspace` is undefined.
    @Test("an unqualified source registers nothing even though the host offered the capability")
    func publicSourceDoesNotArm() throws {
        let fixtures = try makeFixtures()
        defer { fixtures.stop() }
        let h = makeHarness()

        h.coordinator.apply(source: fixtures.publicPage, focusWorkspace: focusing(.focused), into: h.webView)

        #expect(h.registry.installed == nil)
        #expect(h.registry.installCount == 0)
        #expect(h.coordinator.armedScope == nil)
        #expect(h.webView.navigationDelegate == nil)
    }

    @Test("a host offering no capability registers nothing even for a loopback source")
    func withoutCapabilityNothingArms() throws {
        let fixtures = try makeFixtures()
        defer { fixtures.stop() }
        let h = makeHarness()

        h.coordinator.apply(source: fixtures.loopback, focusWorkspace: nil, into: h.webView)

        #expect(h.registry.installed == nil)
        #expect(h.coordinator.armedScope == nil)
        #expect(h.webView.navigationDelegate == nil)
    }

    // The web view is reused across source changes, so a stale registration would hand the next page
    // a capability it never earned.
    @Test("swapping an armed source for an unqualified one removes the handler")
    func switchingToPublicSourceDisarms() throws {
        let fixtures = try makeFixtures()
        defer { fixtures.stop() }
        let h = makeHarness()
        h.coordinator.apply(source: fixtures.loopback, focusWorkspace: focusing(.focused), into: h.webView)
        #expect(h.registry.installed != nil)

        h.coordinator.apply(source: fixtures.publicPage, focusWorkspace: focusing(.focused), into: h.webView)

        #expect(h.registry.installed == nil)
        #expect(h.registry.removeCount >= 1)
        #expect(h.coordinator.armedScope == nil)
        #expect(h.webView.navigationDelegate == nil)
    }

    @Test("swapping between two armed sources rearms the lock on the new one")
    func switchingArmedSourcesRearms() throws {
        let fixtures = try makeFixtures()
        defer { fixtures.stop() }
        let h = makeHarness()
        h.coordinator.apply(source: fixtures.loopback, focusWorkspace: focusing(.focused), into: h.webView)

        h.coordinator.apply(source: fixtures.otherLoopback, focusWorkspace: focusing(.focused), into: h.webView)

        #expect(h.registry.installed != nil)
        let scope = try #require(h.coordinator.armedScope)
        #expect(scope.permitsNavigation(to: fixtures.otherLoopbackOrigin.appendingPathComponent("next"), isMainFrame: true))
        #expect(!scope.permitsNavigation(to: fixtures.loopbackOrigin, isMainFrame: true))
    }

    // The withdrawal has to land now. Waiting for the page to navigate would leave a host that has
    // decided the sidebar may no longer focus workspaces still answering focus requests.
    @Test("withdrawing the capability removes the handler immediately, with no source change")
    func withdrawnCapabilityDisarmsWithoutSourceChange() throws {
        let fixtures = try makeFixtures()
        defer { fixtures.stop() }
        let h = makeHarness()
        h.coordinator.apply(source: fixtures.loopback, focusWorkspace: focusing(.focused), into: h.webView)
        #expect(h.registry.installed != nil)

        h.coordinator.apply(source: fixtures.loopback, focusWorkspace: nil, into: h.webView)

        #expect(h.registry.installed == nil)
        #expect(h.coordinator.armedScope == nil)
        #expect(h.webView.navigationDelegate == nil)
    }

    @Test("offering the capability later arms the handler without waiting for a source change")
    func lateCapabilityArmsWithoutSourceChange() throws {
        let fixtures = try makeFixtures()
        defer { fixtures.stop() }
        let h = makeHarness()
        h.coordinator.apply(source: fixtures.loopback, focusWorkspace: nil, into: h.webView)
        #expect(h.registry.installed == nil)

        h.coordinator.apply(source: fixtures.loopback, focusWorkspace: focusing(.focused), into: h.webView)

        #expect(h.registry.installed != nil)
        #expect(h.coordinator.armedScope != nil)
        #expect(h.webView.navigationDelegate is CustomSidebarNavigationLock)
    }

    // The mount hands down a fresh closure on every SwiftUI update, roughly once a second since the
    // sidebar sits inside a periodic TimelineView. The page must reach the current one.
    @Test("a same-source update swaps the closure the page reaches without re-registering")
    func sameSourceUpdateReplacesClosureInPlace() throws {
        let fixtures = try makeFixtures()
        defer { fixtures.stop() }
        let h = makeHarness()
        h.coordinator.apply(source: fixtures.loopback, focusWorkspace: focusing(.unavailable), into: h.webView)
        let firstInstall = try #require(h.registry.installed)
        #expect(h.registry.installCount == 1)

        h.coordinator.apply(source: fixtures.loopback, focusWorkspace: focusing(.focused), into: h.webView)

        // Still the same registration: the handler was never absent, not even for one update.
        #expect(h.registry.installCount == 1)
        #expect(h.registry.installed === firstInstall)

        let status = firstInstall.resolve(
            messageBody: ["v": 1, "workspaceId": UUID().uuidString],
            isMainFrame: true,
            frameOriginScheme: fixtures.loopbackOrigin.scheme,
            frameOriginHost: fixtures.loopbackOrigin.host,
            frameOriginPort: fixtures.loopbackOrigin.port ?? 0,
            webViewURL: fixtures.loopbackOrigin
        )
        #expect(status == .focused)
    }

    @Test("dismantling removes the handler and the lock")
    func dismantleRemovesBridge() throws {
        let fixtures = try makeFixtures()
        defer { fixtures.stop() }
        let h = makeHarness()
        h.coordinator.apply(source: fixtures.loopback, focusWorkspace: focusing(.focused), into: h.webView)
        #expect(h.registry.installed != nil)

        CustomSidebarWebView.dismantleNSView(h.container, coordinator: h.coordinator)

        #expect(h.registry.installed == nil)
        #expect(h.coordinator.armedScope == nil)
        #expect(h.webView.navigationDelegate == nil)
    }
}
