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
    private func makeCoordinator() -> (CustomSidebarWebView.Coordinator, WKWebView) {
        let webView = WKWebView(frame: .zero)
        let container = CustomSidebarWebContainerView(webView: webView)
        let coordinator = CustomSidebarWebView.Coordinator()
        coordinator.container = container
        coordinator.attach(registry: CustomSidebarFocusHandlerRegistrySpy(), webView: webView)
        return (coordinator, webView)
    }

    private func makeRemoteSource() throws -> (LoopbackHTTPServer, CustomSidebarWebSource) {
        let (server, origin) = try LoopbackHTTPServer.started(body: "<!doctype html><title>fixture</title>")
        return (server, .remote(origin))
    }

    private func unqualifiedURL(for origin: URL) throws -> URL {
        var components = try #require(URLComponents(url: origin, resolvingAgainstBaseURL: false))
        components.host = "localhost"
        return try #require(components.url)
    }

    @Test("an unchanged source with an unchanged token does not reload")
    func unchangedUpdateDoesNotReload() throws {
        let (server, source) = try makeRemoteSource()
        defer { server.stop() }
        let (coordinator, webView) = makeCoordinator()
        coordinator.apply(source: source, focusWorkspace: nil, into: webView)
        let afterFirst = coordinator.issuedLoadCount

        coordinator.apply(source: source, focusWorkspace: nil, into: webView)
        coordinator.apply(source: source, focusWorkspace: nil, into: webView)

        // The steady-state case: a SwiftUI update carrying no new intent must leave the page alone,
        // or a sidebar loses its scroll position roughly once a second.
        #expect(coordinator.issuedLoadCount == afterFirst)
    }

    @Test("an unchanged source with a bumped token reloads")
    func bumpedTokenReloadsUnchangedSource() throws {
        let (server, source) = try makeRemoteSource()
        defer { server.stop() }
        let (coordinator, webView) = makeCoordinator()
        coordinator.apply(source: source, focusWorkspace: nil, into: webView)
        let afterFirst = coordinator.issuedLoadCount

        coordinator.apply(
            source: source,
            reloadToken: CustomSidebarWebReloadToken.initial.bumped(),
            focusWorkspace: nil,
            into: webView
        )

        #expect(coordinator.issuedLoadCount == afterFirst + 1)
    }

    @Test("each further bump reloads again")
    func repeatedBumpsReloadEachTime() throws {
        let (server, source) = try makeRemoteSource()
        defer { server.stop() }
        let (coordinator, webView) = makeCoordinator()
        var token = CustomSidebarWebReloadToken.initial
        coordinator.apply(source: source, reloadToken: token, focusWorkspace: nil, into: webView)

        for expected in 2...4 {
            token = token.bumped()
            coordinator.apply(source: source, reloadToken: token, focusWorkspace: nil, into: webView)
            #expect(coordinator.issuedLoadCount == expected)
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
        let afterFirst = coordinator.issuedLoadCount

        try "<!doctype html><title>two</title>".write(to: fileURL, atomically: true, encoding: .utf8)
        coordinator.apply(
            source: .document(fileURL),
            reloadToken: CustomSidebarWebReloadToken.initial.bumped(),
            focusWorkspace: nil,
            into: webView
        )

        #expect(coordinator.issuedLoadCount == afterFirst + 1)
    }

    // A reload must not quietly re-open a capability the source no longer earns, or the reverse.
    @Test("reloading preserves the arming decision rather than re-deciding it loosely")
    func reloadKeepsArmingCorrect() throws {
        let (server, origin) = try LoopbackHTTPServer.started(body: "<!doctype html><title>fixture</title>")
        defer { server.stop() }
        let publicSource = CustomSidebarWebSource.remote(try unqualifiedURL(for: origin))
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
