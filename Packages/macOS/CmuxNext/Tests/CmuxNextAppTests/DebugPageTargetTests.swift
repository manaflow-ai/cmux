#if DEBUG
import AppKit
@testable import CmuxNextApp
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// `debug.page {page}` reports a page the user can see, never the parked spare: the spare runs the
/// Settings document with no routes, so a probe that read it saw a read-only banner that no
/// visible page showed.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)))
struct DebugPageTargetTests {
    final class Provider: PageProvider {
        func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
            switch op {
            case "cmux.settings.list": return .array([])
            case "cmux.settings.snapshot":
                return ["revision": 1, "schema_hash": "", "effective": .object([:]), "managed": .object([:]), "diagnostics": .array([])]
            default: return .object([:])
            }
        }

        func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                       onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
            PageSubscription {}
        }
    }

    @Test func debugPageReportsTheVisibleSettingsPageNotTheOlderParkedSpare() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var policy = PageHostPool.Policy()
        policy.idleInput = .milliseconds(5)
        let pool = PageHostPool(policy: policy, activity: { 0 }, isTrackingMenu: { false })
        defer { pool.dropSpare() }
        pool.follow(window)
        pool.noteLikely()
        let ready = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            if pool.isSpareReady { return continuation.resume(returning: true) }
            pool.onSpareReady = { _ in continuation.resume(returning: true) }
        }
        #expect(ready)

        // A Settings page opened without the pool while the spare stays parked: the spare is older.
        let page = try #require(PageWebView(descriptor: .settings,
                                            routes: [PageRoute(prefix: "cmux.settings.", provider: Provider())],
                                            route: "#/settings/general"))
        defer { page.close() }
        if let content = window.contentView {
            page.frame = content.bounds
            content.addSubview(page)
        }
        await page.waitUntilLoaded()

        let state = await DebugPages.handle(["page": "cmux.settings", "action": "state"], services: nil)
        #expect(state["hash"]?.stringValue == "#/settings/general", "debug.page read \(state)")
        #expect(state["parked"]?.boolValue != true)
    }
}
#endif
