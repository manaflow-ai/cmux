import AppKit
@testable import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
import WebKit

/// The prepared spare (decision a), the two-process limit (decision b) and the split spare build,
/// in a real WKWebView with the real shell build (GUI host only: cmux-lawrence-2).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3))) struct PageHostPrepareTests {
    static func events(_ host: PageWebView) async throws -> [String] {
        let text = try await host.webKitView.callAsyncJavaScript(
            "return JSON.stringify(globalThis.cmuxShell?.events ?? [])", contentWorld: .page) as? String ?? "[]"
        return try JSONDecoder().decode([String].self, from: Data(text.utf8))
    }

    static func prepared(_ pool: PageHostPool, _ page: String) async {
        if pool.preparedPage == page { return }
        _ = await PageTestWait.value("spare prepared with \(page)") { (done: @escaping (Bool) -> Void) in
            pool.onPrepared = { _, id in if id == page { done(true) } }
        }
    }

    @Test func aPreparedPageIsMountedInTheSpareAndTheClaimOnlyResumesIt() async throws {
        let pool = PageHostPoolTests.pool()
        let window = PageHostPoolTests.window()
        defer { pool.dropSpare(); window.close() }
        pool.follow(window)
        pool.prepare(.shellProbe, routes: [], size: CGSize(width: 300, height: 200))
        await Self.prepared(pool, "cmux.shell.probe")
        let spare = try #require(pool.spareHost)
        #expect(spare.frame.size == CGSize(width: 300, height: 200))
        #expect(!spare.touched)
        let host = try await PageHostPoolTests.claim(pool, .shellProbe, window: window)
        #expect(host === spare)
        let events = try await Self.events(host)
        #expect(events.filter { $0 == "mounted cmux.shell.probe" }.count == 1, "the claim mounted the page again: \(events)")
        #expect(events.contains("resumed cmux.shell.probe"))
        // The next spare prepares the last opened page.
        pool.release(host)
        await Self.prepared(pool, "cmux.shell.probe")
    }

    @Test func aSpareIsBuiltWhileOneHostIsClaimedButNeverAThirdHost() async throws {
        let pool = PageHostPoolTests.pool()
        let window = PageHostPoolTests.window()
        defer { pool.dropSpare(); window.close() }
        pool.follow(window)
        pool.noteLikely()
        await PageHostPoolTests.spareReady(pool)
        let first = try await PageHostPoolTests.claim(pool, .shellProbe, window: window)
        await PageHostPoolTests.spareReady(pool)
        #expect(pool.hostCount == 2)
        let second = try await PageHostPoolTests.claim(pool, .shellProbe, window: window)
        #expect(second !== first)
        #expect(pool.hostCount == 2)
        #expect(!pool.mayBuild, "a third WebContent process would be built")
        pool.release(first)
        pool.release(second)
    }

    @Test func theSpareIsBuiltInSeparateStepsEachMeasured() async throws {
        let pool = PageHostPoolTests.pool()
        let window = PageHostPoolTests.window()
        defer { pool.dropSpare(); window.close() }
        pool.follow(window)
        pool.noteLikely()
        await PageHostPoolTests.spareReady(pool)
        let names = Set(pool.spans.map(\.name))
        for step in ["pool.makeSpare.configure", "pool.makeSpare.create", "pool.makeSpare.park", "pool.makeSpare.load"] {
            #expect(names.contains(step), "no span for \(step): \(names.sorted())")
        }
    }
}
