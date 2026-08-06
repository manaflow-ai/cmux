import AppKit
import CmuxFoundation
import Foundation
import Testing
import WebKit

@testable import CmuxSidebar

@Suite("CustomSidebarWebView focus bridge lifecycle")
@MainActor
struct CustomSidebarFocusBridgeLifecycleTests {
    private let loopback = CustomSidebarWebSource.remote(URL(string: "http://127.0.0.1:8787/")!)
    private let otherLoopback = CustomSidebarWebSource.remote(URL(string: "http://127.0.0.1:9999/")!)
    private let publicPage = CustomSidebarWebSource.remote(URL(string: "https://example.com/")!)

    private struct Harness {
        let coordinator: CustomSidebarWebView.Coordinator
        let webView: WKWebView
        let container: CustomSidebarWebContainerView
        let registry: CustomSidebarFocusHandlerRegistrySpy
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
    func loopbackSourceArms() {
        let h = makeHarness()

        h.coordinator.apply(source: loopback, focusWorkspace: focusing(.focused), into: h.webView)

        #expect(h.registry.installed != nil)
        #expect(h.coordinator.armedScope != nil)
        #expect(h.webView.navigationDelegate is CustomSidebarNavigationLock)
    }

    // The strongest form of "no" for a public page: the handler is never registered, so
    // `window.webkit.messageHandlers.cmuxSidebarFocusWorkspace` is undefined.
    @Test("a public source registers nothing even though the host offered the capability")
    func publicSourceDoesNotArm() {
        let h = makeHarness()

        h.coordinator.apply(source: publicPage, focusWorkspace: focusing(.focused), into: h.webView)

        #expect(h.registry.installed == nil)
        #expect(h.registry.installCount == 0)
        #expect(h.coordinator.armedScope == nil)
        #expect(h.webView.navigationDelegate == nil)
    }

    @Test("a host offering no capability registers nothing even for a loopback source")
    func withoutCapabilityNothingArms() {
        let h = makeHarness()

        h.coordinator.apply(source: loopback, focusWorkspace: nil, into: h.webView)

        #expect(h.registry.installed == nil)
        #expect(h.coordinator.armedScope == nil)
        #expect(h.webView.navigationDelegate == nil)
    }

    // The web view is reused across source changes, so a stale registration would hand the next page
    // a capability it never earned.
    @Test("swapping an armed source for a public one removes the handler")
    func switchingToPublicSourceDisarms() {
        let h = makeHarness()
        h.coordinator.apply(source: loopback, focusWorkspace: focusing(.focused), into: h.webView)
        #expect(h.registry.installed != nil)

        h.coordinator.apply(source: publicPage, focusWorkspace: focusing(.focused), into: h.webView)

        #expect(h.registry.installed == nil)
        #expect(h.registry.removeCount >= 1)
        #expect(h.coordinator.armedScope == nil)
        #expect(h.webView.navigationDelegate == nil)
    }

    @Test("swapping between two armed sources rearms the lock on the new one")
    func switchingArmedSourcesRearms() throws {
        let h = makeHarness()
        h.coordinator.apply(source: loopback, focusWorkspace: focusing(.focused), into: h.webView)

        h.coordinator.apply(source: otherLoopback, focusWorkspace: focusing(.focused), into: h.webView)

        #expect(h.registry.installed != nil)
        let scope = try #require(h.coordinator.armedScope)
        #expect(scope.permitsNavigation(to: URL(string: "http://127.0.0.1:9999/next"), isMainFrame: true))
        #expect(!scope.permitsNavigation(to: URL(string: "http://127.0.0.1:8787/"), isMainFrame: true))
    }

    // The withdrawal has to land now. Waiting for the page to navigate would leave a host that has
    // decided the sidebar may no longer focus workspaces still answering focus requests.
    @Test("withdrawing the capability removes the handler immediately, with no source change")
    func withdrawnCapabilityDisarmsWithoutSourceChange() {
        let h = makeHarness()
        h.coordinator.apply(source: loopback, focusWorkspace: focusing(.focused), into: h.webView)
        #expect(h.registry.installed != nil)

        h.coordinator.apply(source: loopback, focusWorkspace: nil, into: h.webView)

        #expect(h.registry.installed == nil)
        #expect(h.coordinator.armedScope == nil)
        #expect(h.webView.navigationDelegate == nil)
    }

    @Test("offering the capability later arms the handler without waiting for a source change")
    func lateCapabilityArmsWithoutSourceChange() {
        let h = makeHarness()
        h.coordinator.apply(source: loopback, focusWorkspace: nil, into: h.webView)
        #expect(h.registry.installed == nil)

        h.coordinator.apply(source: loopback, focusWorkspace: focusing(.focused), into: h.webView)

        #expect(h.registry.installed != nil)
        #expect(h.coordinator.armedScope != nil)
        #expect(h.webView.navigationDelegate is CustomSidebarNavigationLock)
    }

    // The mount hands down a fresh closure on every SwiftUI update — roughly once a second, since
    // the sidebar sits inside a periodic TimelineView. The page must reach the current one.
    @Test("a same-source update swaps the closure the page reaches without re-registering")
    func sameSourceUpdateReplacesClosureInPlace() throws {
        let h = makeHarness()
        h.coordinator.apply(source: loopback, focusWorkspace: focusing(.unavailable), into: h.webView)
        let firstInstall = try #require(h.registry.installed)
        #expect(h.registry.installCount == 1)

        h.coordinator.apply(source: loopback, focusWorkspace: focusing(.focused), into: h.webView)

        // Still the same registration: the handler was never absent, not even for one update.
        #expect(h.registry.installCount == 1)
        #expect(h.registry.installed === firstInstall)

        let status = firstInstall.resolve(
            messageBody: ["v": 1, "workspaceId": UUID().uuidString],
            isMainFrame: true,
            frameOriginScheme: "http",
            frameOriginHost: "127.0.0.1",
            frameOriginPort: 8787,
            webViewURL: URL(string: "http://127.0.0.1:8787/")
        )
        #expect(status == .focused)
    }

    @Test("dismantling removes the handler and the lock")
    func dismantleRemovesBridge() {
        let h = makeHarness()
        h.coordinator.apply(source: loopback, focusWorkspace: focusing(.focused), into: h.webView)
        #expect(h.registry.installed != nil)

        CustomSidebarWebView.dismantleNSView(h.container, coordinator: h.coordinator)

        #expect(h.registry.installed == nil)
        #expect(h.coordinator.armedScope == nil)
        #expect(h.webView.navigationDelegate == nil)
    }
}
