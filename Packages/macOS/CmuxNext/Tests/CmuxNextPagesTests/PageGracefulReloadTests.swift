@testable import CmuxNextPages
import Foundation
import Testing

/// A web layer change reloads each open Chromium page at its own safe point, as the WebKit views do
/// (``WebBundleGracefulReload``), not all at once (Leo, 2026-11-22: "it's a graceful if not imperceptible
/// state transition all around").
@MainActor
@Suite(.serialized)
struct PageGracefulReloadTests {
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("page-graceful-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    private func page(_ name: String) throws -> PageWebView {
        let descriptor = PageDescriptor(id: "test.graceful-\(name)", resource: "graceful-\(name)", namespaces: [])
        return try #require(PageWebView(descriptor: descriptor, root: root, testRoot: true, routes: [], route: "#/"))
    }

    @Test func aPageThatMayReloadReloadsAtOnce() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let free = try page("free"), noHook = try page("no-hook"), silent = try page("silent")
        defer { [free, noHook, silent].forEach { $0.close() } }
        let reloader = PageGracefulReload()
        reloader.booksLooks = false
        var reloaded: [ObjectIdentifier] = []
        reloader.askOverride = { pages in pages.map { $0 === noHook ? "page.no-hook" : $0 === silent ? "page.no-answer" : nil } }
        reloader.reloadOverride = { reloaded.append(ObjectIdentifier($0)) }
        reloader.reload([free, noHook, silent])
        await reloader.look()
        #expect(Set(reloaded) == Set([free, noHook, silent].map(ObjectIdentifier.init)))
        #expect(reloader.waitingCount == 0)
    }

    @Test func aPageHoldingTextWaitsUntilItIsDone() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let typing = try page("typing"), idle = try page("idle")
        defer { [typing, idle].forEach { $0.close() } }
        let reloader = PageGracefulReload()
        reloader.booksLooks = false
        var answer: String? = "field"
        var reloaded: [ObjectIdentifier] = []
        reloader.askOverride = { pages in pages.map { $0 === typing ? answer : nil } }
        reloader.reloadOverride = { reloaded.append(ObjectIdentifier($0)) }
        reloader.reload([typing, idle])
        await reloader.look()
        #expect(reloaded == [ObjectIdentifier(idle)])
        #expect(reloader.waitingCount == 1)
        answer = nil
        await reloader.look()
        #expect(reloaded == [ObjectIdentifier(idle), ObjectIdentifier(typing)])
        #expect(reloader.waitingCount == 0)
    }

    @Test func aClosedPageStopsWaiting() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let typing = try page("closed")
        let reloader = PageGracefulReload()
        reloader.booksLooks = false
        var reloaded = 0
        reloader.askOverride = { pages in pages.map { _ in "field" } }
        reloader.reloadOverride = { _ in reloaded += 1 }
        reloader.reload([typing])
        await reloader.look()
        #expect(reloader.waitingCount == 1)
        typing.close()
        await reloader.look()
        #expect(reloader.waitingCount == 0)
        #expect(reloaded == 0)
    }

    @Test func aLaterChangeReplacesThePagesStillWaiting() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try page("first"), second = try page("second")
        defer { [first, second].forEach { $0.close() } }
        let reloader = PageGracefulReload()
        reloader.booksLooks = false
        reloader.askOverride = { pages in pages.map { _ in "field" } }
        reloader.reloadOverride = { _ in }
        reloader.reload([first])
        await reloader.look()
        #expect(reloader.waitingCount == 1)
        reloader.reload([first, second])
        #expect(reloader.waitingCount == 2)
        reloader.reload([])
        #expect(reloader.waitingCount == 0)
    }
}
