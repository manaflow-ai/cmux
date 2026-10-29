import AppKit
import CmuxNextCompat
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextSettings
@testable import CmuxNextWakeups
import Foundation
import Testing

/// How a preloaded page's document takes its claim (cx-5vg7), engine-neutral, on a
/// Chromium page whose document the test answers for: an acknowledged claim keeps the document (no
/// reload); a first claim that the document refuses or leaves unanswered reloads it once, and the
/// reloaded document gets the claim at its load; a later document's claim never reloads (no reload
/// loop) and carries no route, so a reload keeps the place the person moved to.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct PagePreloadClaimTests {
    /// The host calls the page's router sent, in order.
    @MainActor final class Sent {
        var envelopes: [JSONValue] = []
        var claims: [JSONValue] { envelopes.filter { $0["op"]?.stringValue == PageWebView.claimOp } }
    }

    private let base: PagePreloadPageTests

    init() throws {
        base = try PagePreloadPageTests()
    }

    /// Lets the claim's reply task and the script queue run, until `done` or 100 turns.
    private static func settle(_ done: () -> Bool) async {
        var turns = 0
        while !done(), turns < 100 {
            await Task.yield()
            turns += 1
        }
    }

    /// How many times the page reloaded its document from script (``PageWebView/reloadDocument()``).
    private static func reloads(_ page: FakeChromiumPage) -> Int {
        page.calls.filter { ($0.params["expression"] as? String)?.contains("location.reload()") == true }.count
    }

    /// A Chromium preload in a shown window whose first document loaded parked, claimed by no open
    /// yet, and the calls its router sends from now on.
    private func loadedPreload(in window: NSWindow, host: WebUIHost,
                               hosting: FakeChromiumHosting) async throws -> (PageWebView, FakeChromiumPage, Sent) {
        let parking = PagePreloadParkingView(frame: .zero)
        window.contentView?.addSubview(parking)
        let view = try base.preload(host, in: parking)
        await view.chromiumStart?.value
        let page = try #require(hosting.made.first)
        page.onEvent?(.devTools(PagePreloadPageTests.frameNavigated))
        page.onEvent?(.devTools(PagePreloadPageTests.loadEventFired))
        #expect(view.loaded && !view.isClaimed)
        let sent = Sent()
        view.router.send = { sent.envelopes.append($0) }
        return (view, page, sent)
    }

    /// A new document of the page commits and loads; the router's sends after the commit go to `sent`.
    private static func reload(_ view: PageWebView, page: FakeChromiumPage, sent: Sent) {
        page.onEvent?(.devTools(PagePreloadPageTests.frameNavigated))
        view.router.send = { sent.envelopes.append($0) }
        page.onEvent?(.devTools(PagePreloadPageTests.loadEventFired))
    }

    /// The document's answer to claim call `call`.
    private static func answer(_ call: JSONValue, claimed: Bool, on view: PageWebView) async {
        _ = await view.router.handle(["t": "ok", "id": call["id"] ?? .null, "value": ["claimed": .bool(claimed)]])
    }

    @Test func anAcknowledgedClaimKeepsTheDocumentAndALaterDocumentKeepsItsPlace() async throws {
        defer { try? FileManager.default.removeItem(at: base.root) }
        let window = PagePreloadPageTests.shownWindow()
        defer { window.close() }
        let hosting = FakeChromiumHosting()
        let host = base.makeHost(hosting)
        let (view, page, sent) = try await loadedPreload(in: window, host: host, hosting: hosting)
        defer { host.close(view) }

        view.bindClaim(routes: [], route: "/settings/agents")
        await Self.settle { !sent.claims.isEmpty }
        let first = try #require(sent.claims.first)
        #expect(first["params"]?["route"]?.stringValue == "#/settings/agents", "the first claim did not carry the open's route")
        await Self.answer(first, claimed: true, on: view)
        await Self.settle { view.lastClaim != nil }
        #expect(view.lastClaim?.path == .acknowledged)
        await Self.settle { false }
        #expect(view.loaded && Self.reloads(page) == 0, "an acknowledged claim reloaded the document")

        // The person moved to another section, then the page reloads (or its renderer crashed and
        // it reloaded): the new document boots parked and is claimed again, at the place it loaded at.
        Self.reload(view, page: page, sent: sent)
        await Self.settle { sent.claims.count == 2 }
        let later = try #require(sent.claims.last)
        #expect(sent.claims.count == 2)
        #expect(later["params"]?["route"] == nil, "a reload's claim sent the page back to the opener's route")
        await Self.answer(later, claimed: true, on: view)
        await Self.settle { !view.claimState.pending }
        #expect(view.lastClaim?.path == .acknowledged && view.loaded)
    }

    @Test func aRefusedFirstClaimReloadsOnceAndALaterRefusalDoesNot() async throws {
        defer { try? FileManager.default.removeItem(at: base.root) }
        let window = PagePreloadPageTests.shownWindow()
        defer { window.close() }
        let hosting = FakeChromiumHosting()
        let host = base.makeHost(hosting)
        let (view, page, sent) = try await loadedPreload(in: window, host: host, hosting: hosting)
        defer { host.close(view) }

        view.bindClaim(routes: [], route: "/settings/agents")
        await Self.settle { !sent.claims.isEmpty }
        let first = try #require(sent.claims.first)
        await Self.answer(first, claimed: false, on: view)
        await Self.settle { view.lastClaim != nil }
        #expect(view.lastClaim?.path == .refused)
        #expect(!view.loaded, "a refused first claim kept the document that already ran")
        await Self.settle { Self.reloads(page) == 1 }
        #expect(Self.reloads(page) == 1)

        // The reloaded document booted parked: its load claims it, with no route (the reload kept it).
        Self.reload(view, page: page, sent: sent)
        await Self.settle { sent.claims.count == 2 }
        let second = try #require(sent.claims.last)
        #expect(sent.claims.count == 2 && second["params"]?["route"] == nil)
        await Self.answer(second, claimed: false, on: view)
        await Self.settle { !view.claimState.pending }
        #expect(view.lastClaim?.path == .refused && view.loaded)
        await Self.settle { false }
        #expect(Self.reloads(page) == 1, "a later document's refusal reloaded it again: a reload loop")
    }

    @Test func anUnansweredFirstClaimReloadsAtTheBudget() async throws {
        defer { try? FileManager.default.removeItem(at: base.root) }
        let window = PagePreloadPageTests.shownWindow()
        defer { window.close() }
        let hosting = FakeChromiumHosting()
        let host = base.makeHost(hosting)
        let (view, page, sent) = try await loadedPreload(in: window, host: host, hosting: hosting)
        defer { host.close(view) }

        // The document never answers; the budget's deadline is visible work the rig runs when it fires it.
        view.bindClaim(routes: [], route: "/settings/agents")
        #expect(view.claimState.deadline.isScheduled && view.claimState.deadline.workClass == .visible)
        await Task.yield()
        #expect(view.lastClaim == nil, "the claim ended before its deadline")
        base.pageDeadlines.fire()
        await Self.settle { view.lastClaim != nil }
        #expect(sent.claims.count == 1)
        #expect(view.lastClaim?.path == .timedOut)
        #expect(!view.loaded)
        await Self.settle { Self.reloads(page) == 1 }
        #expect(Self.reloads(page) == 1, "a silent document was left parked and blank")

        // Its reload is claimed at its load and never reloaded for silence (a reload boots parked again).
        Self.reload(view, page: page, sent: sent)
        await Self.settle { sent.claims.count == 2 }
        #expect(sent.claims.count == 2)
        await Self.settle { false }
        #expect(Self.reloads(page) == 1)
    }
}
