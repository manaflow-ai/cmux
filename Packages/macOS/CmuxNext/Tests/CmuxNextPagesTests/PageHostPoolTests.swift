import AppKit
@testable import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
import WebKit

/// The one prewarmed page host, in a real WKWebView with the real shell build (GUI host only:
/// cmux-lawrence-2). Page A is the shell's probe page acting as a page: it writes every store it
/// can, a global, a pending call and a subscription; page B must see none of it, after a reset in
/// the same host and on a new host after a release.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3))) struct PageHostPoolTests {
    /// Serves the probe's namespace: `slow` stays pending, `events` is a stream it can still emit on.
    final class ProbeProvider: PageProvider {
        var calls: [String] = []
        var cancelled = 0
        var emit: (@MainActor (JSONValue) -> Void)?
        var slow: CheckedContinuation<JSONValue, any Error>?

        func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
            calls.append(op)
            guard op == "cmux.shell.probe.slow" else { return ["ok": true] }
            slowArrivedDone?()
            slowArrivedDone = nil
            return try await withCheckedThrowingContinuation { slow = $0 }
        }

        func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                       onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
            emit = onEvent
            return PageSubscription { [weak self] in self?.cancelled += 1 }
        }

        func waitForSlow() async {
            guard slow == nil else { return }
            _ = await PageTestWait.value("slow call reached the provider") { (done: @escaping (Bool) -> Void) in
                self.slowArrivedDone = { done(true) }
            }
        }
        var slowArrivedDone: (() -> Void)?

        func finish() {
            slow?.resume(returning: ["late": true])
            slow = nil
        }
    }

    static let pageA = """
    const ctx = globalThis.__cmuxShellProbe;
    localStorage.setItem('a', '1');
    sessionStorage.setItem('a', '1');
    globalThis.leakedByA = { token: 'a' };
    let idb = false;
    try {
      idb = await new Promise((resolve) => {
        const open = indexedDB.open('a-db', 1);
        open.onupgradeneeded = () => open.result.createObjectStore('s');
        open.onerror = () => resolve(false);
        open.onsuccess = () => {
          const db = open.result;
          const tx = db.transaction('s', 'readwrite');
          tx.objectStore('s').put('secret', 'k');
          tx.oncomplete = () => { db.close(); resolve(true); };
          tx.onerror = () => resolve(false);
        };
      });
    } catch { idb = false; }
    let cache = false;
    try {
      if (globalThis.caches) {
        const opened = await caches.open('a-cache');
        await opened.put('/a', new Response('secret'));
        cache = true;
      }
    } catch { cache = false; }
    await ctx.client.subscribe('cmux.shell.probe.events', () => { document.documentElement.dataset.lateEvent = '1'; });
    return JSON.stringify({ idb, cache });
    """

    static let pendingCall = """
    try { await globalThis.__cmuxShellProbe.client.call('cmux.shell.probe.slow', {}); return 'resolved'; }
    catch (error) { return error.code || 'other'; }
    """

    /// Page B opens A's database by name: a fresh database (old version 0, no store) means A's
    /// rows are gone; null means IndexedDB is not there.
    static let pageB = """
    let databases = null;
    try { if (indexedDB.databases) databases = (await indexedDB.databases()).map((d) => d.name); } catch { databases = null; }
    let cacheKeys = null;
    try { if (globalThis.caches) cacheKeys = await caches.keys(); } catch { cacheKeys = null; }
    const idbLeaked = await new Promise((resolve) => {
      let fresh = false;
      let open;
      try { open = indexedDB.open('a-db'); } catch { resolve(null); return; }
      open.onupgradeneeded = (event) => { fresh = event.oldVersion === 0; };
      open.onerror = () => resolve(null);
      open.onsuccess = () => {
        const db = open.result;
        const had = db.objectStoreNames.contains('s');
        db.close();
        indexedDB.deleteDatabase('a-db');
        resolve(had && !fresh);
      };
    });
    return JSON.stringify({
      local: localStorage.length, session: sessionStorage.length, global: typeof globalThis.leakedByA,
      idbLeaked, databases, cacheKeys, late: document.documentElement.dataset.lateEvent ?? null,
      mounted: document.querySelectorAll('[data-shell-page]').length
    });
    """

    struct Seen: Decodable, Equatable {
        var local: Int
        var session: Int
        var global: String
        var idbLeaked: Bool?
        var databases: [String]?
        var cacheKeys: [String]?
        var late: String?
        var mounted: Int
    }

    /// The shell's own view of `host`, for a timed-out wait.
    static func shellState(_ host: PageWebView?) async -> String {
        guard let host else { return "no host" }
        let script = "return JSON.stringify({ready: document.readyState, shell: typeof globalThis.cmuxShell, current: globalThis.cmuxShell?.current ?? null, events: globalThis.cmuxShell?.events ?? null, handler: typeof globalThis.webkit?.messageHandlers?.cmuxPage})"
        let state = (try? await host.webKitView.callAsyncJavaScript(script, contentWorld: .page)) as? String ?? "no answer"
        // Deliver a claim by hand: if the shell records it now, the host's own claim never ran.
        let manual = "globalThis.__cmuxPageReceive && globalThis.__cmuxPageReceive({t: 'call', id: 999999, op: 'page.claim', params: {page: 'cmux.shell.probe'}}); return JSON.stringify({receive: typeof globalThis.__cmuxPageReceive, events: globalThis.cmuxShell?.events ?? null})"
        let after = (try? await host.webKitView.callAsyncJavaScript(manual, contentWorld: .page)) as? String ?? "no answer"
        return "loaded=\(host.isLoaded) url=\(host.webKitView.url?.absoluteString ?? "nil") window=\(host.window != nil) "
            + "\(state) manual=\(after)"
    }

    static func js(_ host: PageWebView, _ script: String) async throws -> Any? {
        try await host.webKitView.callAsyncJavaScript(script, contentWorld: .page)
    }

    static func seen(_ host: PageWebView) async throws -> Seen {
        let text = try #require(try await js(host, pageB) as? String)
        return try JSONDecoder().decode(Seen.self, from: Data(text.utf8))
    }

    static func reply(_ stage: String = "host call reply",
                      _ send: (@escaping (Result<JSONValue, PageError>) -> Void) -> Void) async -> Result<JSONValue, PageError> {
        await PageTestWait.value(stage, send) ?? .failure(.closed)
    }

    /// A pool claim that returns once the shell has mounted the page.
    static func claim(_ pool: PageHostPool, _ descriptor: PageDescriptor, routes: [PageRoute] = [],
                      window: NSWindow) async throws -> PageWebView {
        var host: PageWebView?
        let result = await reply("claim of \(descriptor.id) mounted") { done in
            host = pool.claim(descriptor, routes: routes, window: window, mounted: done)
            let claimed = host
            PageTestWait.onTimeout = { await shellState(claimed) }
            if host == nil { done(.failure(.closed)) }
        }
        #expect(result == .success(["page": .string(descriptor.id)]))
        return try #require(host)
    }

    /// A window that is never shown. Not released when closed: ARC owns it (a window released on
    /// close and again by ARC crashes a later test).
    static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    /// Waits for the pool's spare (the test fails at the deadline).
    static func spareReady(_ pool: PageHostPool) async {
        if pool.isSpareReady { return }
        _ = await PageTestWait.value("spare ready") { (done: @escaping (Bool) -> Void) in
            pool.onSpareReady = { _ in done(true) }
        }
    }

    /// A pool with a short quiet period and no outside activity.
    static func pool() -> PageHostPool {
        PageID.registerBundledRoot(PageShellFixture.webviewsApp, for: PageDescriptor.shell.id)
        var policy = PageHostPool.Policy()
        policy.idleInput = .milliseconds(5)
        return PageHostPool(policy: policy, activity: { 0 }, isTrackingMenu: { false })
    }

    static func loadedHost() async throws -> PageWebView {
        PageID.registerBundledRoot(PageShellFixture.webviewsApp, for: PageDescriptor.shell.id)
        let host = try #require(PageWebView(pooledHost: .shell))
        await host.waitUntilLoaded()
        #expect(await host.preloadShellPages(), "the shell did not boot")
        return host
    }

    /// Page A acts, then the page goes away (`leave`), then page B is mounted (by `next`, which
    /// returns its host): B reads nothing of A, A's stream is cancelled, A's pending call is closed.
    func checkNothingLeaks(provider: ProbeProvider, host: PageWebView, leave: () async -> Void,
                           next: () async throws -> PageWebView) async throws {
        struct Wrote: Decodable { var idb: Bool; var cache: Bool }
        let wroteText = try await Self.js(host, Self.pageA) as? String ?? "{}"
        let wrote = try JSONDecoder().decode(Wrote.self, from: Data(wroteText.utf8))
        // IndexedDB must work in a page host, or this test proves nothing about it.
        #expect(wrote.idb, "page A could not open IndexedDB")
        print("PAGE_TEST_STAGE storage in page A: indexedDB \(wrote.idb), cache storage \(wrote.cache)")
        let outcome = Task { try await Self.js(host, Self.pendingCall) as? String }
        await provider.waitForSlow()
        #expect(host.router.subscriptionCount == 1)

        await leave()
        #expect(provider.cancelled == 1)
        #expect(host.router.subscriptionCount == 0)
        // A's stream and A's call answer late: nothing reaches any page.
        provider.emit?(["late": true])
        provider.finish()

        let b = try await next()
        let seen = try await Self.seen(b)
        #expect(seen.local == 0 && seen.session == 0)
        #expect(seen.global == "undefined")
        #expect(seen.late == nil)
        #expect(seen.mounted == 1)
        #expect(seen.idbLeaked == false, "page B saw page A's IndexedDB rows (or had no IndexedDB)")
        // indexedDB.databases(), when WebKit has it: page B's own probe database only, deleted again.
        if let databases = seen.databases { #expect(databases.isEmpty, "indexedDB.databases() in page B: \(databases)") }
        if wrote.cache { #expect(seen.cacheKeys == [], "page B saw page A's Cache Storage") }
        // A's pending call: closed in the same host; gone with its document on a retired host.
        if b === host { #expect(try await outcome.value == "cmux.protocol.closed") } else { outcome.cancel() }
    }

    @Test func aResetLeavesTheNextPageNothingOfTheLast() async throws {
        let host = try await Self.loadedHost()
        defer { host.close() }
        let provider = ProbeProvider()
        let routes = [PageRoute(prefix: "cmux.shell.probe.", provider: provider)]
        host.retarget(descriptor: .shellProbe, routes: routes)
        PageTestWait.onTimeout = { await Self.shellState(host) }
        #expect(await Self.reply { host.sendClaim(reply: $0) } == .success(["page": "cmux.shell.probe"]))
        try await checkNothingLeaks(provider: provider, host: host, leave: {
            _ = await Self.reply { host.resetShellPage(reply: $0) }
        }, next: {
            host.retarget(descriptor: .shellProbe, routes: [])
            _ = await Self.reply { host.sendClaim(reply: $0) }
            return host
        })
    }

    @Test func aNewHostAfterAReleaseCannotSeeTheOldHostsStorage() async throws {
        PageID.registerBundledRoot(PageShellFixture.webviewsApp, for: PageDescriptor.shell.id)
        let window = Self.window()
        var policy = PageHostPool.Policy()
        policy.idleInput = .milliseconds(5)
        let pool = PageHostPool(policy: policy, activity: { 0 }, isTrackingMenu: { false })
        func spare() async {
            if pool.isSpareReady { return }
            _ = await PageTestWait.value("spare ready") { (done: @escaping (Bool) -> Void) in
                pool.onSpareReady = { _ in done(true) }
            }
        }
        #expect(pool.claim(.shellProbe, routes: [], window: window) == nil)
        await spare()
        let provider = ProbeProvider()
        let a = try await Self.claim(pool, .shellProbe, routes: [PageRoute(prefix: "cmux.shell.probe.", provider: provider)],
                                     window: window)
        try await checkNothingLeaks(provider: provider, host: a, leave: {
            #expect(a.touched)
            pool.release(a)
            #expect(pool.spareHost !== a)
        }, next: {
            await spare()
            let b = try await Self.claim(pool, .shellProbe, window: window)
            #expect(b !== a)
            // A retired host's non-persistent data store is never reused.
            #expect(b.webKitView.configuration.websiteDataStore !== a.webKitView.configuration.websiteDataStore)
            return b
        })
        #expect(pool.spans.contains { $0.name == "pool.makeSpare.create" })
        pool.dropSpare()
        pool.claimedHosts.forEach(pool.release)
        window.close()
    }

    @Test func onlyAnUntouchedHostIsRecycled() async throws {
        PageID.registerBundledRoot(PageShellFixture.webviewsApp, for: PageDescriptor.shell.id)
        let window = Self.window()
        var policy = PageHostPool.Policy()
        policy.idleInput = .milliseconds(5)
        let pool = PageHostPool(policy: policy, activity: { 0 }, isTrackingMenu: { false })
        func spare() async {
            if pool.isSpareReady { return }
            _ = await PageTestWait.value("spare ready") { (done: @escaping (Bool) -> Void) in
                pool.onSpareReady = { _ in done(true) }
            }
        }
        pool.follow(window)
        pool.noteLikely()
        await spare()
        // Untouched: claimed and released with no op and no event; reset and parked again.
        let first = try await Self.claim(pool, .shellProbe, window: window)
        #expect(!first.touched)
        pool.release(first)
        #expect(pool.spareHost === first)
        #expect(pool.isSpareReady)
        // Reset, then prepared again with the last claimed page (decision a).
        await PageHostPrepareTests.prepared(pool, "cmux.shell.probe")
        #expect(first.descriptor.id == "cmux.shell.probe")
        #expect(!first.touched)
        // One op: never recycled.
        let second = try await Self.claim(pool, .shellProbe, window: window)
        #expect(second === first)
        _ = try await Self.js(second, "try { await globalThis.__cmuxShellProbe.client.call('cmux.shell.probe.x', {}); } catch {} return 1")
        #expect(second.touched)
        pool.release(second)
        #expect(pool.spareHost !== second)
        pool.dropSpare()
        window.close()
    }

    @Test func theSpareWaitsForAQuietPeriod() async throws {
        PageID.registerBundledRoot(PageShellFixture.webviewsApp, for: PageDescriptor.shell.id)
        let window = Self.window()
        var policy = PageHostPool.Policy()
        policy.idleInput = .milliseconds(5)
        var reads = 0
        // Busy (terminal output, frames, input) for the first deadlines, then quiet.
        let pool = PageHostPool(policy: policy, activity: { reads += 1; return UInt64(min(reads, 6)) }, isTrackingMenu: { false })
        pool.follow(window)
        #expect(pool.spareHost == nil)
        _ = await PageTestWait.value("spare built after the quiet period") { (done: @escaping (Bool) -> Void) in
            pool.onSpareReady = { _ in done(true) }
            pool.noteLikely()
        }
        #expect(reads >= 7)
        #expect(pool.isSpareReady)
        pool.dropSpare()
        window.close()
    }
}
