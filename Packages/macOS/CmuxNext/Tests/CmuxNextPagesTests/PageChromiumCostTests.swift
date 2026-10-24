import AppKit
import CmuxNextDesign
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import Foundation
import Testing
import WebKit

/// A cmux page in Chromium makes no renderer while nobody has seen it (speed-of-sound-DESIGN.md
/// 3.1 and 3.3, perf-lead.md F3): its Chromium page, and so its renderer process, starts only when
/// the view first shows (in a window, not hidden, not parked), or when its owner has work only the
/// page can do. Before this, every page made its renderer in `init`, shown or not.
///
/// A started page that hides is not frozen by the hide: it keeps booting and taking its pushes, as
/// a WebKit page does (a freeze on every hide stopped a chat's seeded prompt and adopt at document
/// start, and queued every push for a renderer that runs no script). The hibernation's freeze
/// policy freezes it after a grace (``PageFreezePolicy``); it thaws before it shows and before any
/// call or push reaches it.
///
/// A Chromium page's own WebKit view stays empty: no script, load or reload reaches it, so it
/// starts no WebKit web content process.
@MainActor
struct PageChromiumCostTests {
    private let root: URL
    private let descriptor = PageDescriptor(id: "test.chromium-cost", resource: "chromium-cost", namespaces: [])
    private let stage = PageTestWindow()

    /// A workspace view parked without hiding (`WorkspaceContentView`'s alpha parking).
    private final class ParkingBox: NSView, ParkingContainer {
        var isParkedOffScreen = false {
            didSet { notifyParkingChange() }
        }
    }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("page-chromium-cost-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    private func makeView(_ hosting: FakeChromiumHosting) throws -> PageWebView {
        let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], route: "#/start", chromium: hosting))
        view.chromiumClock = PageTestClock.never
        return view
    }

    /// The page's first message reached the host (its paint probe): the page is past its start.
    private func reachHost(_ view: PageWebView, _ page: FakeChromiumPage) async {
        let painted: Bool? = await PageTestWait.value("first message") { done in
            view.whenPainted { done(true) }
            page.onEvent?(.devTools(FakeChromiumPage.bindingCall(["name": PagePaintProbe.handlerName, "body": 1])))
        }
        #expect(painted == true)
    }

    private func container() -> NSView {
        stage.show(NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300)))
    }

    /// Records what a page reports to the freeze policy; freezes nothing by itself.
    private final class RecordingFreezePolicy: PageFreezePolicy {
        var woke = 0
        var noLongerHidden = 0
        func hiddenPageWoke(_ page: PageWebView) { woke += 1 }
        func pageIsNoLongerHidden(_ page: PageWebView) { noLongerHidden += 1 }
    }

    /// Loads, reloads and host scripts that reached `view`'s own WebKit view: any of them makes a
    /// view that loaded nothing launch a WebKit web content process.
    private func webKitRequests(_ view: PageWebView) throws -> Int {
        try #require(view.webKitView as? PageWKWebView).documentRequests
    }

    @Test func aPageMadeOutOfSightStartsNoRendererUntilItShows() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let view = try makeView(hosting)
        #expect(view.engineDecision == .chromium)
        // Made, not shown: no Chromium page is asked for, now or later.
        await view.chromiumStart?.value
        #expect(hosting.made.isEmpty)
        // No WebKit document either: a call meant for the document never wakes the unused WebKit view.
        #expect(view.documentWebView == nil)

        stage.show(view)
        let start = try #require(view.chromiumStart)
        await start.value
        #expect(hosting.made.count == 1)
        let page = try #require(hosting.made.first)
        #expect(page.loaded == [descriptor.url(route: "#/start")])
        #expect(page.visibility == [true])
        view.close()
    }

    @Test func aPageInAHiddenContainerStartsWhenTheContainerShows() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let pane = container()
        pane.isHidden = true
        let view = try makeView(hosting)
        pane.addSubview(view)
        // In the window but hidden (another tab of the pane shows): still no renderer.
        await view.chromiumStart?.value
        #expect(hosting.made.isEmpty)

        pane.isHidden = false
        await view.chromiumStart?.value
        #expect(hosting.made.count == 1)
        #expect(hosting.made.first?.visibility == [true])
        view.close()
    }

    /// A move inside one window may send no window or hide hook: the superview hook sees it.
    @Test func aPageMovedInsideItsWindowStartsAndHidesWithItsContainer() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let hidden = container()
        hidden.isHidden = true
        let shown = container()
        let view = try makeView(hosting)
        hidden.addSubview(view)
        await view.chromiumStart?.value
        #expect(hosting.made.isEmpty)

        shown.addSubview(view)
        await view.chromiumStart?.value
        let page = try #require(hosting.made.first)
        #expect(page.visibility == [true])

        hidden.addSubview(view)
        #expect(page.visibility == [true, false])
        view.close()
    }

    /// A parked workspace (alpha parking, not hidden) is out of sight too.
    @Test func aPageUnderAParkedContainerStartsWhenItUnparksAndHidesWhenItParks() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let workspace = stage.show(ParkingBox(frame: NSRect(x: 0, y: 0, width: 400, height: 300)))
        workspace.isParkedOffScreen = true
        let view = try makeView(hosting)
        workspace.addSubview(view)
        await view.chromiumStart?.value
        #expect(hosting.made.isEmpty)

        workspace.isParkedOffScreen = false
        await view.chromiumStart?.value
        let page = try #require(hosting.made.first)
        #expect(page.visibility == [true])

        workspace.isParkedOffScreen = true
        #expect(page.visibility == [true, false])
        view.close()
    }

    /// A page that hides right after its start (its input readiness `post(false)` at document
    /// start, before React mounts) is not frozen: it stays open and its pushes still run in it, so
    /// a chat's seeded prompt and adopt go out while it is hidden, and no push waits on a show.
    /// Each visibility change is sent once.
    @Test func aHiddenPageKeepsRunningAndTakesItsPushes() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let pane = container()
        let view = try makeView(hosting)
        pane.addSubview(view)
        await view.chromiumStart?.value
        let page = try #require(hosting.made.first)
        page.onEvent?(.devTools(FakeChromiumPage.bindingCall(["name": PageInputReadiness.handlerName, "body": false])))

        view.isHidden = true
        pane.isHidden = true
        #expect(page.visibility == [true, false])
        await reachHost(view, page)
        #expect(!page.closed)

        let push = "window.__cmuxPushWhileHidden = 1"
        let ran: Bool? = await PageTestWait.value("push to a hidden page") { done in
            page.onCall = { [weak page] in
                guard let page else { return }
                if page.calls.contains(where: { ($0.params["expression"] as? String)?.contains(push) == true }) { done(true) }
            }
            view.evaluate(push)
        }
        #expect(ran == true)

        pane.isHidden = false
        view.isHidden = false
        #expect(page.visibility == [true, false, true])
        view.close()
    }

    /// An owner with work only the page can do (a chat made out of sight with a seeded prompt)
    /// starts it at once; it stays hidden until it shows.
    @Test func anOwnerStartsAPageOutOfSight() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let view = try makeView(hosting)
        view.startWithoutShowing()
        await view.chromiumStart?.value
        let page = try #require(hosting.made.first)
        #expect(page.loaded == [descriptor.url(route: "#/start")])
        #expect(page.visibility == [false])

        stage.show(view)
        #expect(hosting.made.count == 1)
        #expect(page.visibility == [false, true])
        view.close()
    }

    /// No script, load or reload reaches a Chromium page's own WebKit view, before or after the
    /// Chromium page starts: the interface scale, the theme and a crash reload all go to Chromium,
    /// and the WebKit view starts no web content process. A call into a page that has not started
    /// says so (``PageScriptError/notStarted``) instead of answering nil like a page that returned null.
    @Test func aChromiumPageSendsNothingToItsWebKitView() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let view = try makeView(hosting)
        // Made: the init sent nothing to the WebKit view.
        #expect(try webKitRequests(view) == 0)
        // Before the start: no engine gets the reload or the route; the start loads the route.
        view.reloadPage()
        view.open(route: "#/other")
        await #expect(throws: PageScriptError.notStarted) { _ = try await view.callPageScript("return 1") }

        stage.show(view)
        await view.chromiumStart?.value
        let page = try #require(hosting.made.first)
        #expect(page.loaded == [descriptor.url(route: "#/other")])
        #expect(page.reloads == 0)
        // The document finished: the interface scale and the theme go into it, then again on a change.
        page.onEvent?(.finished)
        view.applyUIScale()
        view.applyTheme(force: true)
        view.reloadPage()
        #expect(page.reloads == 1)
        let reached: Bool? = await PageTestWait.value("scripts in Chromium") { done in
            let check = { [weak page] in
                if page?.calls.contains(where: { $0.method == "Runtime.evaluate" && $0.params["silent"] as? Bool == true }) == true { done(true) }
            }
            page.onCall = check
            check()
        }
        #expect(reached == true)

        #expect(view.webKitView.url == nil)
        #expect(try webKitRequests(view) == 0, "a script, load or reload reached the Chromium page's WebKit view")
        view.close()
    }

    /// The engine is decided again at the first show, which can be hours after the page was made
    /// (a restored tab): a page whose person chose WebKit meanwhile, or whose Chromium became
    /// unavailable, opens in WebKit at once, at its route, and asks Chromium for nothing.
    @Test(arguments: [true, false])
    func aPageThatNoLongerShowsInChromiumOpensInWebKitAtItsFirstShow(choseWebKit: Bool) async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let view = try makeView(hosting)
        #expect(view.isWaitingForFirstShow)
        if choseWebKit { hosting.preference = .webkit } else { hosting.isAvailable = false }

        stage.show(view)
        await view.chromiumStart?.value
        #expect(hosting.made.isEmpty)
        #expect(view.engineDecision.engine == .webKit)
        #expect(!view.isWaitingForFirstShow)
        #expect(!view.webKitView.isHidden)
        #expect(view.documentWebView === view.webKitView)
        #expect(view.webKitView.url == descriptor.url(route: "#/start"))
        view.close()
    }

    /// The freeze policy decides when a hidden page freezes; the page reports each change once,
    /// freezes only once it booted, thaws before a push and before it shows, and a push restarts
    /// its grace.
    @Test func aHiddenPageFreezesOnlyForThePolicyAndThawsBeforeAPushOrAShow() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = RecordingFreezePolicy()
        let hosting = FakeChromiumHosting()
        hosting.freezePolicy = policy
        let pane = container()
        let view = try makeView(hosting)
        pane.addSubview(view)
        await view.chromiumStart?.value
        let page = try #require(hosting.made.first)
        #expect(policy.noLongerHidden == 1)

        pane.isHidden = true
        #expect(policy.woke == 1)
        // Still booting: a freeze now would stop its start (a chat's seeded prompt).
        #expect(view.freezeWhileHidden() == false)
        #expect(page.freezes.isEmpty)

        await reachHost(view, page)
        #expect(policy.woke == 2) // the grace starts again at the first message
        #expect(view.freezeWhileHidden())
        #expect(view.isChromiumFrozen)
        #expect(page.freezes == [true])
        #expect(view.freezeWhileHidden() == false) // sent once

        view.evaluate("window.__cmuxPush = 1")
        #expect(page.freezes == [true, false])
        #expect(policy.woke == 3)

        #expect(view.freezeWhileHidden())
        pane.isHidden = false
        #expect(Array(page.lifecycle.suffix(2)) == ["thawed", "shown"])
        #expect(!view.isChromiumFrozen)
        #expect(policy.noLongerHidden == 2)
        #expect(view.freezeWhileHidden() == false) // it shows
        view.close()
    }

    /// A host call into a frozen hidden page (a snapshot, a script) thaws it first.
    @Test func aCallIntoAFrozenPageThawsItFirst() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let pane = container()
        let view = try makeView(hosting)
        pane.addSubview(view)
        await view.chromiumStart?.value
        let page = try #require(hosting.made.first)
        pane.isHidden = true
        await reachHost(view, page)
        #expect(view.freezeWhileHidden())

        _ = try await view.callPageScript("return 1")
        #expect(page.freezes == [true, false])
        #expect(page.lifecycle.last == "thawed")
        view.close()
    }
}
