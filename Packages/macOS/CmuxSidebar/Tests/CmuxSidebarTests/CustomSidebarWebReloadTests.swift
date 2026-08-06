import AppKit
import CmuxFoundation
import Foundation
import Testing
import WebKit

@testable import CmuxSidebar

/// `cmux sidebar reload` on a hosted page.
///
/// The source-changed guard exists because `updateNSView` fires on every unrelated invalidation, and
/// a sidebar lives inside a periodic TimelineView. But an explicit reload is exactly the case that
/// guard skips: same path, same URL, different bytes.
@Suite("CustomSidebarWebView reload")
@MainActor
struct CustomSidebarWebReloadTests {
    private let source = CustomSidebarWebSource.remote(URL(string: "http://127.0.0.1:8787/")!)

    private func makeCoordinator() -> (CustomSidebarWebView.Coordinator, WKWebView) {
        let webView = WKWebView(frame: .zero)
        let container = CustomSidebarWebContainerView(webView: webView)
        let coordinator = CustomSidebarWebView.Coordinator()
        coordinator.container = container
        coordinator.attach(registry: CustomSidebarFocusHandlerRegistrySpy(), webView: webView)
        return (coordinator, webView)
    }

    /// Whether a load was actually issued, observed through the web view's own loading state.
    private func didLoad(_ webView: WKWebView) -> Bool {
        webView.isLoading || webView.url != nil
    }

    @Test("an unchanged source with an unchanged token does not reload")
    func unchangedUpdateDoesNotReload() {
        let (coordinator, webView) = makeCoordinator()
        coordinator.apply(source: source, focusWorkspace: nil, into: webView)
        webView.stopLoading()

        coordinator.apply(source: source, focusWorkspace: nil, into: webView)

        // The steady-state case: a SwiftUI update that carries no new intent must leave the page
        // alone, or a sidebar loses its scroll position roughly once a second.
        #expect(!webView.isLoading)
    }

    @Test("an unchanged source with a bumped token reloads")
    func bumpedTokenReloadsUnchangedSource() {
        let (coordinator, webView) = makeCoordinator()
        coordinator.apply(source: source, focusWorkspace: nil, into: webView)
        webView.stopLoading()

        coordinator.apply(
            source: source,
            reloadToken: CustomSidebarWebReloadToken.initial.bumped(),
            focusWorkspace: nil,
            into: webView
        )

        #expect(didLoad(webView))
    }

    @Test("each further bump reloads again")
    func repeatedBumpsReloadEachTime() {
        let (coordinator, webView) = makeCoordinator()
        var token = CustomSidebarWebReloadToken.initial
        coordinator.apply(source: source, reloadToken: token, focusWorkspace: nil, into: webView)

        for _ in 0..<3 {
            webView.stopLoading()
            token = token.bumped()
            coordinator.apply(source: source, reloadToken: token, focusWorkspace: nil, into: webView)
            #expect(didLoad(webView))
        }
    }

    @Test("a document source reloads on a bumped token too")
    func documentReloads() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sidebar-reload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("board.html")
        try "<!doctype html><title>one</title>".write(to: fileURL, atomically: true, encoding: .utf8)

        let (coordinator, webView) = makeCoordinator()
        coordinator.apply(source: .document(fileURL), focusWorkspace: nil, into: webView)
        webView.stopLoading()

        try "<!doctype html><title>two</title>".write(to: fileURL, atomically: true, encoding: .utf8)
        coordinator.apply(
            source: .document(fileURL),
            reloadToken: CustomSidebarWebReloadToken.initial.bumped(),
            focusWorkspace: nil,
            into: webView
        )

        #expect(didLoad(webView))
    }

    // A reload must not quietly re-open a capability the source no longer earns, or the reverse.
    @Test("reloading preserves the arming decision rather than re-deciding it loosely")
    func reloadKeepsArmingCorrect() {
        let publicSource = CustomSidebarWebSource.remote(URL(string: "https://example.com/")!)
        let (coordinator, webView) = makeCoordinator()
        coordinator.apply(
            source: publicSource,
            focusWorkspace: { _ in .focused },
            into: webView
        )
        #expect(coordinator.armedScope == nil)

        coordinator.apply(
            source: publicSource,
            reloadToken: CustomSidebarWebReloadToken.initial.bumped(),
            focusWorkspace: { _ in .focused },
            into: webView
        )

        #expect(coordinator.armedScope == nil)
    }

    @Test("a bumped token is not equal to the token it came from")
    func bumpIsObservable() {
        let token = CustomSidebarWebReloadToken.initial
        #expect(token != token.bumped())
        #expect(token.bumped() == CustomSidebarWebReloadToken(revision: 1))
    }
}
