#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextCompat
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextSettings
import Foundation
import Testing

/// The host half of the oracle's `webviews` facet: `cmux.page.oracle.state` maps the page's reply
/// to state, `unknown_op` to unserved, `closed` to gone and any other error to a throw; a page that never replies is
/// timed out at the deadline and its call leaves the router; a page that is not loaded answers loading
/// and the parked spare is never asked; a page's `cmux.page.oracle.changed` and its loads wake the page host's feed.
/// Run: `swift test --filter PageOracleStateTests`.
@MainActor
struct PageOracleStateTests {
    private static let descriptor = PageDescriptor(id: "cmux.oracle-test", resource: "oracle-test", processGroup: .solo,
                                                   namespaces: [])

    /// A router whose page answers each host call with `reply` (nil: never answers); records the calls sent.
    private static func router(reply: (@MainActor (JSONValue) -> JSONValue)?) -> (PageRouter, () -> [JSONValue]) {
        let router = PageRouter(descriptor: descriptor, routes: [])
        var sent: [JSONValue] = []
        router.send = { [weak router] envelope in
            sent.append(envelope)
            guard let reply, let router else { return }
            let answer = reply(envelope)
            // task-owner: the fake page's reply, one hop after the call is pending
            Task { @MainActor in _ = await router.handle(answer) }
        }
        return (router, { sent })
    }

    private static func error(_ code: String) -> @MainActor (JSONValue) -> JSONValue {
        { envelope in ["t": "err", "id": envelope["id"] ?? .null, "code": .string(code), "message": "x"] }
    }

    @Test func aReplyIsThePagesState() async throws {
        let state: JSONValue = ["route": "/", "selection": .null, "panels": [], "draftSha256": .null]
        let (router, sent) = Self.router { envelope in ["t": "ok", "id": envelope["id"] ?? .null, "value": state] }
        let answer = try await router.oracleState(within: .seconds(1), clock: PageTestClock.never)
        #expect(answer == .state(state))
        #expect(sent().first?["op"]?.stringValue == PageRouter.oracleStateOp)
    }

    @Test func unknownOpIsUnservedAndClosedIsGone() async throws {
        let (unserved, _) = Self.router(reply: Self.error("cmux.protocol.unknown_op"))
        #expect(try await unserved.oracleState(within: .seconds(1), clock: PageTestClock.never) == .unserved)
        let (closed, _) = Self.router(reply: Self.error("cmux.protocol.closed"))
        #expect(try await closed.oracleState(within: .seconds(1), clock: PageTestClock.never) == .gone)
        let (shut, _) = Self.router(reply: nil)
        shut.close()
        #expect(try await shut.oracleState(within: .seconds(1), clock: PageTestClock.never) == .gone)
    }

    @Test func anotherErrorIsThePagesDefect() async {
        let (router, _) = Self.router(reply: Self.error("cmux.oracle.no_digest"))
        await #expect(throws: PageError(code: "cmux.oracle.no_digest", message: "x")) {
            try await router.oracleState(within: .seconds(1), clock: PageTestClock.never)
        }
    }

    @Test func aPageThatNeverRepliesTimesOut() async throws {
        let (router, sent) = Self.router(reply: nil)
        #expect(try await router.oracleState(within: .seconds(1), clock: PageTestClock.immediate) == .timedOut)
        #expect(sent().count == 1)
        // The timed-out call left the router; a late reply resolves nothing.
        #expect(router.pendingHostCalls == 0)
        let late = try #require(sent().first)
        #expect(await router.handle(["t": "ok", "id": late["id"] ?? .null, "value": .object([:])]) == .null)
    }

    @Test func thePagesChangeCallRunsTheHookAndIsAnswered() async {
        let router = PageRouter(descriptor: Self.descriptor, routes: [])
        var changes = 0
        router.oracleStateChanged = { changes += 1 }
        let reply = await router.handle(["t": "call", "id": 4, "op": .string(PageRouter.oracleStateChangedOp), "params": .object([:])])
        #expect(reply["t"]?.stringValue == "ok")
        #expect(changes == 1)
    }

    // MARK: The page view

    private func withPage(_ body: (WebUIHost, PageWebView) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("page-oracle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
        let host = WebUIHost(chromium: nil, openPanel: nil, memory: QuietMemoryRegistry(),
                             deadlines: LifecycleDeadlineRig.never)
        let page = try #require(host.open(PageOpenRequest(descriptor: Self.descriptor, root: root, routes: [])))
        defer { host.close(page) }
        try await body(host, page)
    }

    @Test func aPageThatIsNotLoadedIsLoadingAndTheParkedSpareIsNotAsked() async throws {
        try await withPage { _, page in
            page.loaded = false
            // Read first, then expect: inside this closure the #expect expansion does not see the typed throw as handled.
            let unloaded = try await page.oracleState(within: .seconds(1), clock: PageTestClock.never)
            #expect(unloaded == .loading)
            let parking = PagePreloadParkingView(frame: .zero)
            parking.addSubview(page)
            let parked = try await page.oracleState(within: .seconds(1), clock: PageTestClock.never)
            #expect(parked == nil)
        }
    }

    @Test func theHostsFeedWakesOnALoadAndOnThePagesChangeCall() async throws {
        try await withPage { host, page in
            page.loaded = false
            var changes = host.oracleChanges.subscribe().makeAsyncIterator()
            page.loaded = true
            #expect(await changes.next() != nil)
            _ = await page.router.handle(["t": "call", "id": 1, "op": .string(PageRouter.oracleStateChangedOp), "params": .object([:])])
            #expect(await changes.next() != nil)
        }
    }
}
#endif
