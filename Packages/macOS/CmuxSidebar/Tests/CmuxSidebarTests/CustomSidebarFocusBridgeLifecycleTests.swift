import AppKit
import Foundation
import Testing
import WebKit

@testable import CmuxSidebar

@Suite("CustomSidebarWebView focus bridge lifecycle")
@MainActor
struct CustomSidebarFocusBridgeLifecycleTests {
    private func makeCoordinator(
        offersFocus: Bool = true
    ) -> (CustomSidebarWebView.Coordinator, WKWebView, CustomSidebarWebContainerView) {
        let webView = WKWebView(frame: .zero)
        let container = CustomSidebarWebContainerView(webView: webView)
        let coordinator = CustomSidebarWebView.Coordinator()
        coordinator.container = container
        if offersFocus {
            coordinator.focusWorkspace = { _ in .focused }
        }
        return (coordinator, webView, container)
    }

    @Test("a loopback source arms the bridge and locks the frame")
    func loopbackSourceArms() {
        let (coordinator, webView, _) = makeCoordinator()

        coordinator.load(.remote(URL(string: "http://127.0.0.1:8787/")!), into: webView)

        #expect(coordinator.armedScope != nil)
        #expect(webView.navigationDelegate is CustomSidebarNavigationLock)
    }

    // The strongest form of "no" for a public page: the handler simply does not exist, so
    // `window.webkit.messageHandlers.cmuxSidebarFocusWorkspace` is undefined.
    @Test("a public source arms nothing even though the host offered a focus handler")
    func publicSourceDoesNotArm() {
        let (coordinator, webView, _) = makeCoordinator()

        coordinator.load(.remote(URL(string: "https://example.com/")!), into: webView)

        #expect(coordinator.armedScope == nil)
        #expect(webView.navigationDelegate == nil)
    }

    @Test("a host that offers no focus handler arms nothing even for a loopback source")
    func withoutHostHandlerNothingArms() {
        let (coordinator, webView, _) = makeCoordinator(offersFocus: false)

        coordinator.load(.remote(URL(string: "http://127.0.0.1:8787/")!), into: webView)

        #expect(coordinator.armedScope == nil)
        #expect(webView.navigationDelegate == nil)
    }

    // The web view is reused across source changes, so a stale registration would hand the next
    // page a capability it never qualified for.
    @Test("switching from an armed source to a public one drops the bridge")
    func switchingToPublicSourceDisarms() {
        let (coordinator, webView, _) = makeCoordinator()

        coordinator.load(.remote(URL(string: "http://127.0.0.1:8787/")!), into: webView)
        #expect(coordinator.armedScope != nil)

        coordinator.load(.remote(URL(string: "https://example.com/")!), into: webView)

        #expect(coordinator.armedScope == nil)
        #expect(webView.navigationDelegate == nil)
    }

    @Test("switching between two armed sources rearms on the new one")
    func switchingArmedSourcesRearms() throws {
        let (coordinator, webView, _) = makeCoordinator()

        coordinator.load(.remote(URL(string: "http://127.0.0.1:8787/")!), into: webView)
        coordinator.load(.remote(URL(string: "http://127.0.0.1:9999/")!), into: webView)

        let scope = try #require(coordinator.armedScope)
        #expect(scope.permitsNavigation(to: URL(string: "http://127.0.0.1:9999/next"), isMainFrame: true))
        #expect(!scope.permitsNavigation(to: URL(string: "http://127.0.0.1:8787/"), isMainFrame: true))
    }

    @Test("dismantling removes the handler and the lock")
    func dismantleRemovesBridge() {
        let (coordinator, webView, container) = makeCoordinator()
        coordinator.load(.remote(URL(string: "http://127.0.0.1:8787/")!), into: webView)
        #expect(coordinator.armedScope != nil)

        CustomSidebarWebView.dismantleNSView(container, coordinator: coordinator)

        #expect(coordinator.armedScope == nil)
        #expect(webView.navigationDelegate == nil)
        // A handler left behind would trap the next install under the same name; a clean install
        // after dismantle is the observable proof it was removed.
        CustomSidebarFocusBridge(
            scope: CustomSidebarFocusScope(source: .remote(URL(string: "http://127.0.0.1:8787/")!))!,
            focusWorkspace: { _ in .focused }
        ).install(on: webView.configuration.userContentController)
        CustomSidebarFocusBridge.uninstall(from: webView.configuration.userContentController)
    }
}
