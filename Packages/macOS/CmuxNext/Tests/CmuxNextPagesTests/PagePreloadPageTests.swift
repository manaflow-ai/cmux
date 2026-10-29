import AppKit
import CmuxNextCompat
import CmuxNextMemory
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextWakeups
import Foundation
import Testing
import WebKit

/// Settings, History and Cloud through the preload slot with a real ``PageWebView``,
/// the PageHostPool tests ported onto ``PagePreloadSlot``: the page loads parked in its own engine
/// (Chromium, not a WebKit spare), waits hidden and frozen in a parking in a shown window, and the
/// claim in the open's turn thaws it, shows it, binds the open's routes and claims its document, and
/// every later document of the page (a reload) gets the claim again. Memory pressure closes it.
/// How a document answers the claim: `PagePreloadClaimTests`; the coordinator: `PagePreloadsTests`.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct PagePreloadPageTests {
    let root: URL
    let descriptor = PageDescriptor(id: "test.preload-page", resource: "preload-page", processGroup: .solo, namespaces: [])
    /// The slot's deadlines on a wake-up queue only the test fires.
    let rig = LifecycleDeadlineRig()
    /// The pages' own deadlines (the claim's fallback, ``PageWebView/deadlines``) on another queue only the test
    /// fires, so firing one never runs the other's.
    let pageDeadlines = LifecycleDeadlineRig()
    /// The app's memory coordinator over a pressure source the test drives; the host registers its slot with it.
    let memory = PageTestMemory()
    static let key = PagePreloadSlot.Key("page.test")
    static let size = NSSize(width: 800, height: 600)
    static let frameNavigated = #"{"method":"Page.frameNavigated","params":{"frame":{"id":"A","url":"cmux-page://test.preload-page/"}}}"#
    static let loadEventFired = #"{"method":"Page.loadEventFired","params":{"timestamp":1}}"#

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("page-preload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    /// A borderless window ordered in off screen.
    static func shownWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -4_000, y: -4_000, width: 900, height: 640),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        return window
    }

    /// One main-actor turn: what the page queued on the main run loop runs first.
    static func nextTurn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            RunLoop.main.perform(inModes: [.common]) { continuation.resume() }
        }
    }

    /// A host with its preload slot installed, as the composition root does.
    func makeHost(_ hosting: FakeChromiumHosting?, lazy: Bool = false) -> WebUIHost {
        let host = WebUIHost(chromium: hosting, openPanel: nil, memory: memory.coordinator,
                             deadlines: pageDeadlines.scheduler, startsPagesAtFirstShow: lazy)
        host.preload = PagePreloadSlot(parkState: .frozenHidden, deadlines: rig.scheduler)
        return host
    }

    func parkedRequest() -> PageOpenRequest {
        PageOpenRequest(descriptor: descriptor, root: root, routes: [], parked: true)
    }

    /// Whether the page's document-start scripts park it.
    private static func bootsParked(_ view: PageWebView) -> Bool {
        view.userContent.userScripts.contains { $0.source == PageWebView.parkedScript }
    }

    /// Preloads a page of `host` in `parking` and returns it.
    func preload(_ host: WebUIHost, in parking: PagePreloadParkingView) throws -> PageWebView {
        let slot = try #require(host.preload)
        var made: PageWebView?
        let held = slot.preload(Self.key, size: Self.size, in: parking) { _ in
            made = host.open(parkedRequest())
            return made
        }
        #expect(held)
        return try #require(made)
    }

    @Test func aParkedOpenBootsParkedAndATabOpenDoesNot() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let host = makeHost(nil)
        let view = try #require(host.open(parkedRequest()))
        defer { host.close(view) }
        #expect(view.isPooled && Self.bootsParked(view) && !view.isClaimed)
        let tab = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        defer { host.close(tab) }
        #expect(!tab.isPooled && !Self.bootsParked(tab))

        // A page that was not made parked takes no claim and claims no document at its load.
        tab.bindClaim(routes: [], route: "/elsewhere")
        #expect(!tab.isClaimed && tab.route == nil)
        tab.documentFinished()
        #expect(!tab.claimState.pending)
    }

    /// The preload is the page's own engine: with Chromium the default, no WebKit document loads for
    /// it (PageHostPool built a WebKit Settings host even then).
    @Test func aChromiumPreloadLoadsParkedInChromium() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let window = Self.shownWindow()
        defer { window.close() }
        let parking = PagePreloadParkingView(frame: .zero)
        window.contentView?.addSubview(parking)
        let hosting = FakeChromiumHosting()
        let host = makeHost(hosting)
        let view = try preload(host, in: parking)
        defer { host.close(view) }
        #expect(view.engineDecision == .chromium)
        await view.chromiumStart?.value
        let page = try #require(hosting.made.first)
        #expect(view.webKitPieces == nil, "a WebKit engine was built beside the Chromium preload")
        #expect(page.loaded == [descriptor.url()])
        #expect(page.calls.contains { $0.method == "Page.addScriptToEvaluateOnNewDocument" &&
            (($0.params["source"] as? String)?.contains(PageWebView.parkedScript) == true) })
        #expect(view.isParkedSpare)
    }

    /// Park: hidden, then frozen, after the first paint (a Chromium page gives no cover: its picture
    /// has no alpha). Claim: thawed before shown, in the claiming container, bound to the open; its
    /// document, still loading, gets the claim at its load, and a reload's document gets it again.
    @Test func aClaimThawsShowsAndBindsThePageAndEachDocumentGetsTheClaim() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let window = Self.shownWindow()
        defer { window.close() }
        let parking = PagePreloadParkingView(frame: .zero)
        window.contentView?.addSubview(parking)
        let hosting = FakeChromiumHosting()
        let host = makeHost(hosting)
        let slot = try #require(host.preload)
        let view = try preload(host, in: parking)
        defer { host.close(view) }
        await view.chromiumStart?.value
        let page = try #require(hosting.made.first)

        let painted: Bool? = await PageTestWait.value("paint") { done in
            view.whenPainted { done(true) } // after the slot's own wait, which parks the page
            page.onEvent?(.devTools(FakeChromiumPage.bindingCall(["name": PagePaintProbe.handlerName, "body": 5])))
        }
        #expect(painted == true)
        #expect(slot.phase == .parked && slot.isFrozen)
        #expect(view.isHidden, "a parked page is hidden in its parking: the engine reads it hidden")
        #expect(Array(page.lifecycleSteps.suffix(2)) == [.visible(false), .frozen(true)], "hidden before frozen")

        let tab = NSView(frame: NSRect(origin: .zero, size: Self.size))
        window.contentView?.addSubview(tab)
        let claim = try #require(slot.claim(Self.key, into: tab, frame: tab.bounds))
        #expect(claim.page === view && !claim.covered)
        #expect(slot.count == 0)
        #expect(view.superview === tab && !view.isHidden && !view.isParkedSpare)
        let steps = page.lifecycleSteps
        let thaw = try #require(steps.lastIndex(of: .frozen(false)))
        #expect(steps.last == .visible(true) && thaw < steps.count - 1, "thawed before shown")

        view.bindClaim(routes: [], route: "/settings/general", documentAttributes: ["cloud-machines-layout": "cards"])
        #expect(view.isClaimed && view.route == "#/settings/general")
        #expect(view.liveDocumentAttributes["cloud-machines-layout"] == "cards", "a later document would boot without the open's attributes")
        #expect(!view.claimState.pending, "a document still loading gets its claim at its load")
        page.onEvent?(.devTools(Self.frameNavigated))
        page.onEvent?(.devTools(Self.loadEventFired))
        #expect(view.loaded && view.claimState.pending)

        // A reload: the new document boots parked too, and its load claims it again.
        page.onEvent?(.devTools(Self.frameNavigated))
        #expect(!view.claimState.pending)
        page.onEvent?(.devTools(Self.loadEventFired))
        #expect(view.claimState.pending, "a claimed page's reloaded document was left parked")
    }

    /// The host's memory coordinator registration drops the parked page (it closes), and no preload
    /// starts until pressure is normal again: PageHostPool's spare rule, on the slot.
    @Test func memoryPressureClosesThePreloadAndHoldsTheNextUntilNormal() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let window = Self.shownWindow()
        defer { window.close() }
        let parking = PagePreloadParkingView(frame: .zero)
        window.contentView?.addSubview(parking)
        let hosting = FakeChromiumHosting()
        let host = makeHost(hosting)
        let slot = try #require(host.preload)
        let view = try preload(host, in: parking)
        await view.chromiumStart?.value
        let page = try #require(hosting.made.first)

        memory.send(.warning)
        #expect(slot.count == 0 && view.superview == nil)
        #expect(page.closed, "the dropped preload kept its renderer")
        var madeUnderPressure = false
        let started = slot.preload(Self.key, size: Self.size, in: parking) { _ in
            madeUnderPressure = true
            return nil
        }
        #expect(!started && !madeUnderPressure)
        memory.send(.normal)
        #expect(slot.allowsPreload)
    }

    /// The preload waits in its parking, out of the person's sight and input, in a shown window, and
    /// moves to another window's parking without a reload (PageHostPool's follow of the key window).
    @Test func thePreloadWaitsOutOfSightAndMovesWindowsWithoutAReload() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let window = Self.shownWindow()
        defer { window.close() }
        let parking = PagePreloadParkingView(frame: .zero)
        window.contentView?.addSubview(parking)
        let host = makeHost(nil)
        let slot = try #require(host.preload)
        let view = try preload(host, in: parking)
        defer { host.close(view) }
        let content = try #require(window.contentView)
        #expect(view.window === window && view.isParkedSpare)
        #expect(!parking.frame.intersects(content.bounds))
        #expect(parking.hitTest(NSPoint(x: parking.frame.midX, y: parking.frame.midY)) == nil)
        let url = view.webView.url

        let second = Self.shownWindow()
        defer { second.close() }
        let other = PagePreloadParkingView(frame: .zero)
        second.contentView?.addSubview(other)
        let held = slot.preload(Self.key, size: Self.size, in: other) { _ in
            Issue.record("the same key made a second page")
            return nil
        }
        #expect(held)
        #expect(view.window === second && view.superview === other)
        #expect(view.webView.url == url, "the move reloaded the page")
    }
}
