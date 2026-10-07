import AppKit
@testable import CmuxNextPages
import Foundation
import Testing
import WebKit

/// Behavioral coverage for a pooled page host. These tests run in the GUI host because WebKit
/// must create a real content process to prove the spare was claimed and its storage was isolated.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)))
struct PageHostPoolTests {
    @Test func aSecondPageOpenClaimsThePrewarmedHost() async throws {
        let window = Self.window()
        defer { window.close() }
        let pool = Self.pool()
        pool.follow(window)
        pool.noteLikely()
        await Self.spareReady(pool)

        let first = try #require(pool.claim(.settings, routes: [], window: window))
        #expect(pool.claims.last?.spare == true)

        await Self.spareReady(pool)
        let second = try #require(pool.claim(.history, routes: [], window: window))
        #expect(pool.claims.last?.spare == true)
        #expect(second !== first)

        pool.release(first)
        pool.release(second)
        pool.dropSpare()
    }

    @Test func aReusedHostCannotReadThePreviousHostsStorage() async throws {
        let window = Self.window()
        defer { window.close() }
        let pool = Self.pool()
        pool.follow(window)
        pool.noteLikely()
        await Self.spareReady(pool)

        let first = try #require(pool.claim(.settings, routes: [], window: window))
        await first.waitUntilLoaded()
        _ = try await first.webKitView.callAsyncJavaScript(
            "localStorage.setItem('pool-secret', 'a'); return localStorage.length;",
            contentWorld: .page)
        first.touched = true
        let firstStore = first.webKitView.configuration.websiteDataStore
        pool.release(first)

        await Self.spareReady(pool)
        let second = try #require(pool.claim(.settings, routes: [], window: window))
        await second.waitUntilLoaded()
        let count = try await second.webKitView.callAsyncJavaScript(
            "return localStorage.length;", contentWorld: .page) as? Int
        #expect(count == 0)
        #expect(second.webKitView.configuration.websiteDataStore !== firstStore)

        pool.release(second)
        pool.dropSpare()
    }

    @Test func resettingAnUntouchedHostClearsThePreviousPagesStorage() async throws {
        let window = Self.window()
        defer { window.close() }
        var policy = PageHostPool.Policy()
        policy.idleInput = .milliseconds(5)
        policy.maximumHosts = 1 // Keep the spare slot free for the same host's reset.
        let pool = PageHostPool(policy: policy, activity: { 0 }, isTrackingMenu: { false })
        defer { pool.dropSpare(); pool.claimedHosts.forEach(pool.release) }
        pool.follow(window)
        pool.noteLikely()
        await Self.spareReady(pool)

        let first = try #require(pool.claim(.settings, routes: [], window: window, focus: false))
        await first.waitUntilLoaded()
        let originalView = first.webKitView
        let originalStore = originalView.configuration.websiteDataStore
        let probe = PageStorageProbe()
        let wroteCache = try await probe.write(first)
        #expect(!first.touched)
        pool.release(first)
        #expect(pool.spareHost === first)
        await Self.spareReady(pool)

        let second = try #require(pool.claim(.settings, routes: [], window: window, focus: false))
        #expect(second === first)
        #expect(second.webKitView === originalView)
        #expect(second.webKitView.configuration.websiteDataStore === originalStore)
        await second.waitUntilLoaded()
        try await probe.expectEmpty(second, cacheWasAvailable: wroteCache)
        pool.release(second)
    }

    @Test func aThirdPartyPageIdCannotMountInAPooledHost() throws {
        let host = try #require(PageWebView(pooledHost: .settings))
        defer { host.close() }
        let thirdParty = PageDescriptor(id: "com.example.page", resource: "settings", namespaces: ["com.example.page."])
        #expect(!host.retarget(descriptor: thirdParty, routes: []))
        #expect(host.descriptor == .settings)
    }

    @Test func pageViewsShareOneProcessPoolButKeepSeparateNonPersistentStores() throws {
        let pooled = try #require(PageWebView(pooledHost: .settings))
        let second = try #require(PageWebView(pooledHost: .settings))
        let ordinary = try #require(PageWebView(descriptor: .settings, routes: []))
        defer { pooled.close(); second.close(); ordinary.close() }
        let views = [pooled, second, ordinary]
        #expect(views.allSatisfy { $0.webKitView.configuration.processPool === PageProcessPool.shared })
        let stores = views.map { $0.webKitView.configuration.websiteDataStore }
        #expect(stores.allSatisfy { !$0.isPersistent })
        #expect(stores[0] !== stores[1] && stores[1] !== stores[2])
    }

    private static func pool() -> PageHostPool {
        var policy = PageHostPool.Policy()
        policy.idleInput = .milliseconds(5)
        return PageHostPool(policy: policy, activity: { 0 }, isTrackingMenu: { false })
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
