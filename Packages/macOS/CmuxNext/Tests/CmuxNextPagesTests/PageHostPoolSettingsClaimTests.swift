import AppKit
import CmuxNextSettings
@testable import CmuxNextPages
import Foundation
import Testing

/// A Settings page opened from the prewarmed spare (every Settings open after the first, in any
/// window, incognito or not) must read its settings through the routes of the claim. The spare
/// runs the Settings document before any claim, with no routes, so its first reads fail.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)))
struct PageHostPoolSettingsClaimTests {
    final class RecordingProvider: PageProvider {
        var ops: [String] = []
        var streams: [String] = []
        var onRecord: (() -> Void)?

        func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
            ops.append(op)
            onRecord?()
            switch op {
            case "cmux.settings.list":
                return [["key": "test.row", "value": .null, "default": .null, "customized": false, "managed": .null]]
            case "cmux.settings.snapshot":
                return ["revision": 1, "schema_hash": "", "effective": .object([:]), "managed": .object([:]), "diagnostics": .array([])]
            default: return .object([:])
            }
        }

        func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                       onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
            streams.append(stream)
            onRecord?()
            return PageSubscription {}
        }

        var readAndListened: Bool {
            ops.contains("cmux.settings.list") && ops.contains("cmux.settings.snapshot")
                && streams.contains("cmux.settings.changed")
        }
    }

    @Test func aSettingsPageClaimedFromTheSpareInASecondWindowReadsTheClaimsRoutes() async throws {
        let first = Self.window()
        let second = Self.window()
        defer { first.close(); second.close() }
        var policy = PageHostPool.Policy()
        policy.idleInput = .milliseconds(5)
        let pool = PageHostPool(policy: policy, activity: { 0 }, isTrackingMenu: { false })
        defer { pool.dropSpare(); pool.claimedHosts.forEach(pool.release) }
        pool.follow(first)
        pool.follow(second)
        pool.noteLikely()
        await Self.spareReady(pool)
        // In the app the spare stays parked for seconds or longer. Its Settings document holds its
        // reads until a claim binds routes, so it never shows the failed-read banner.
        let spare = try #require(pool.spareHost)
        try await Task.sleep(for: .seconds(1))
        let parkedState = try await spare.webKitView.callAsyncJavaScript(
            "return document.querySelector('[data-read-only]')?.getAttribute('data-read-only') ?? null;",
            contentWorld: .page) as? String
        #expect(parkedState == nil, "the parked spare must not read through its empty router")

        let provider = RecordingProvider()
        let routes = [PageRoute(prefix: "cmux.settings.", provider: provider)]
        let page = try #require(pool.claim(.settings, routes: routes, route: "#/settings/general",
                                           window: second, focus: false))
        #expect(pool.claims.last?.spare == true)
        if let content = second.contentView {
            page.frame = content.bounds
            content.addSubview(page)
        }

        let read = await PageTestWait.value("settings read through the claim's routes") { (done: @escaping (Bool) -> Void) in
            if provider.readAndListened { return done(true) }
            provider.onRecord = { if provider.readAndListened { done(true) } }
        }
        provider.onRecord = nil
        #expect(read == true, "ops \(provider.ops), streams \(provider.streams)")
        #expect(await Self.banner(in: page, becomes: "none") == "none", "the claimed page shows no read-only banner")
    }

    /// Polls the Settings page's read-only banner (`loadFailed`, `disconnected` or `none`) until it
    /// is `expected` or 20 s pass, and returns the last state (nil: the page never rendered).
    private static func banner(in host: PageWebView, becomes expected: String) async -> String? {
        var last: String?
        for _ in 0..<200 {
            let state = try? await host.webKitView.callAsyncJavaScript("""
            if (!document.querySelector('.settings')) return null;
            const banner = document.querySelector('[data-read-only]');
            if (banner) return banner.getAttribute('data-read-only');
            return document.querySelector('.content h1') ? 'none' : null;
            """, contentWorld: .page) as? String
            last = state
            if state == expected { return state }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return last
    }

    private static func spareReady(_ pool: PageHostPool) async {
        if pool.isSpareReady { return }
        _ = await PageTestWait.value("page host spare ready") { (done: @escaping (Bool) -> Void) in
            pool.onSpareReady = { _ in done(true) }
        }
    }

    private static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }
}
