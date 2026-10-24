import AppKit
import CmuxNextDesign
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextResources
import Foundation
import Testing
import WebKit

/// A cmux page in Chromium makes no renderer while nobody has seen it (speed-of-sound-DESIGN.md
/// 3.1 and 3.3, perf-lead.md F3): its Chromium page, and so its renderer process, starts only when
/// the view first shows (in a window, not hidden, not parked), or when its owner has work only the
/// page can do. Before this, every page made its renderer in `init`, shown or not.
///
/// A started page that hides is not frozen by the hide: it keeps booting and finishes what it was
/// asked, as a WebKit page does (a freeze on every hide stopped a chat's seeded prompt and adopt at
/// document start). The hibernation's freeze policy freezes it after a grace (``PageFreezePolicy``)
/// once it said it booted and no page message is being handled; a window that is covered,
/// minimized or ordered out counts as unseen too. While frozen, a push does not thaw it (that kept
/// every page the host feeds awake): its streams keep their newest state for the thaw, and the
/// theme and scale scripts are sent again at the thaw. It thaws before it is seen and before a host
/// call or script reaches it.
///
/// A Chromium page's own WebKit view stays empty: no script, load or reload reaches it, so it
/// starts no WebKit web content process.
@MainActor
struct PageChromiumCostTests {
    private let root: URL
    private let descriptor = PageDescriptor(id: "test.chromium-cost", resource: "chromium-cost", namespaces: ["test."])
    private let stage = PageTestWindow()

    /// A workspace view parked without hiding (`WorkspaceContentView`'s alpha parking).
    private final class ParkingBox: NSView, ParkingContainer {
        var isParkedOffScreen = false {
            didSet { notifyParkingChange() }
        }
    }

    /// The page's providers: a state stream the test drives, a stream of the person's input, and a
    /// call that waits until the test answers it.
    private final class TestProvider: PageProvider {
        var emitState: ((JSONValue) -> Void)?
        var emitLog: ((JSONValue) -> Void)?
        var callStarted: (() -> Void)?
        private var waiting: CheckedContinuation<Void, Never>?

        func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
            await withCheckedContinuation { continuation in
                waiting = continuation
                callStarted?()
            }
            return .object([:])
        }

        func answer() {
            waiting?.resume()
            waiting = nil
        }

        func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                       onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
            if stream == "test.log" {
                emitLog = onEvent
                return PageSubscription(freezing: .input) {}
            }
            emitState = onEvent
            return PageSubscription(freezing: .newest) {}
        }
    }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("page-chromium-cost-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    private func makeView(_ hosting: FakeChromiumHosting, provider: TestProvider = TestProvider()) throws -> PageWebView {
        let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: [PageRoute(prefix: "test.", provider: provider)],
                                            route: "#/start", chromium: hosting))
        view.chromiumClock = PageTestClock.never
        return view
    }

    /// Posts `body` from the page (`window.webkit.messageHandlers.cmuxPage`) and waits for the
    /// bridge's reply to it.
    @discardableResult
    private func post(_ body: [String: Any], seq: Int, view: PageWebView, page: FakeChromiumPage) async -> Bool {
        let replied: Bool? = await PageTestWait.value("reply to \(body["t"] ?? "?")") { done in
            page.onCall = { [weak page] in
                if page?.calls.contains(where: { ($0.params["expression"] as? String)?.contains("\(ChromiumPageHostBridge.resolveName)?.(\(seq),") == true }) == true {
                    done(true)
                }
            }
            page.onEvent?(.devTools(FakeChromiumPage.bindingCall(["name": PageHostTrust.handlerName, "seq": seq, "body": body])))
        }
        return replied == true
    }

    /// The page's client said its start is done (pageClient.ts `BOOTED`).
    private func boot(_ view: PageWebView, _ page: FakeChromiumPage) async {
        #expect(await post(["t": "booted"], seq: 1, view: view, page: page))
        #expect(view.chromiumSession?.booted == true)
    }

    /// Evaluations sent to the page whose expression contains `marker`.
    private func evaluations(_ page: FakeChromiumPage, containing marker: String) -> Int {
        page.calls.filter { $0.method == "Runtime.evaluate" && ($0.params["expression"] as? String)?.contains(marker) == true }.count
    }

    /// Waits until an evaluation containing `marker` reached the page.
    private func waitForEvaluation(_ page: FakeChromiumPage, containing marker: String) async -> Bool {
        let reached: Bool? = await PageTestWait.value("evaluation of \(marker)") { done in
            let check = { [weak page] in
                guard let page else { return }
                if page.calls.contains(where: { $0.method == "Runtime.evaluate" && ($0.params["expression"] as? String)?.contains(marker) == true }) {
                    done(true)
                }
            }
            page.onCall = check
            check()
        }
        return reached == true
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

    /// The WebKit web content process of `webView`, if one appears within `limit`: a script or a load
    /// sent to a view that loaded nothing launches one, and its id shows once the launch ends.
    private func webContentProcess(of webView: WKWebView, within limit: Duration) async -> Int32? {
        let end = ContinuousClock.now + limit
        while ContinuousClock.now < end {
            if let pid = WebContentProcess.identifier(of: webView) { return pid }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return WebContentProcess.identifier(of: webView)
    }

    /// A started page in a pane, booted, hidden, with a freeze policy that records.
    private func hiddenBootedPage(provider: TestProvider = TestProvider()) async throws
        -> (PageWebView, FakeChromiumPage, NSView, RecordingFreezePolicy, FakeChromiumHosting) {
        let policy = RecordingFreezePolicy()
        let hosting = FakeChromiumHosting(freezePolicy: policy)
        let pane = container()
        let view = try makeView(hosting, provider: provider)
        pane.addSubview(view)
        await view.chromiumStart?.value
        let page = try #require(hosting.made.first)
        pane.isHidden = true
        await boot(view, page)
        return (view, page, pane, policy, hosting)
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
        await boot(view, page)
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
        #expect(await webContentProcess(of: view.webKitView, within: .seconds(2)) == nil)
        view.close()
    }

    /// The freeze policy decides when an unseen page freezes; the page reports each change once,
    /// freezes only once it said it booted, thaws before a host script and before it is seen, and
    /// a host script restarts its grace.
    @Test func aHiddenPageFreezesOnlyForThePolicyAndThawsBeforeAScriptOrAShow() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = RecordingFreezePolicy()
        let hosting = FakeChromiumHosting(freezePolicy: policy)
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

        await boot(view, page)
        #expect(policy.woke > 1) // the grace starts again once it booted
        #expect(view.freezeWhileHidden())
        #expect(view.isChromiumFrozen)
        #expect(view.chromiumLifecycle == "frozen")
        #expect(page.freezes == [true])
        #expect(view.freezeWhileHidden() == false) // sent once

        let woke = policy.woke
        view.evaluate("window.__cmuxScript = 1")
        #expect(page.freezes == [true, false])
        #expect(policy.woke == woke + 1)

        #expect(view.freezeWhileHidden())
        pane.isHidden = false
        #expect(Array(page.lifecycle.suffix(2)) == ["thawed", "shown"])
        #expect(!view.isChromiumFrozen)
        #expect(policy.noLongerHidden == 2)
        #expect(view.freezeWhileHidden() == false) // it is seen
        view.close()
    }

    /// A host call into a frozen hidden page (a snapshot, a script) thaws it first.
    @Test func aCallIntoAFrozenPageThawsItFirst() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (view, page, _, _, _) = try await hiddenBootedPage()
        #expect(view.freezeWhileHidden())

        _ = try await view.callPageScript("return 1")
        #expect(page.freezes == [true, false])
        #expect(page.lifecycle.last == "thawed")
        view.close()
    }

    /// The reason a hidden page kept running: a push thawed it. Now a stream's newest state waits
    /// in the host while the page is frozen, the page stays frozen, and the thaw sends only the
    /// newest event; only the person's input to the page thaws it for its event.
    @Test func aPushDoesNotThawAFrozenPageAndItGetsTheNewestStateAtTheThaw() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = TestProvider()
        let (view, page, pane, _, _) = try await hiddenBootedPage(provider: provider)
        #expect(await post(["t": "sub", "id": 1, "stream": "test.state"], seq: 2, view: view, page: page))
        #expect(await post(["t": "sub", "id": 2, "stream": "test.log"], seq: 3, view: view, page: page))
        let emitState = try #require(provider.emitState)
        #expect(view.freezeWhileHidden())

        emitState(["state": "pushed-while-frozen-1"])
        emitState(["state": "pushed-while-frozen-2"])
        emitState(["state": "pushed-while-frozen-3"])
        #expect(page.freezes == [true], "a push thawed the hidden page")
        #expect(view.router.frozen.count == 1)

        pane.isHidden = false
        #expect(await waitForEvaluation(page, containing: "pushed-while-frozen-3"))
        #expect(evaluations(page, containing: "pushed-while-frozen-1") == 0)
        #expect(evaluations(page, containing: "pushed-while-frozen-2") == 0)

        pane.isHidden = true
        #expect(view.freezeWhileHidden())
        provider.emitLog?(["change": "log-while-frozen"])
        #expect(page.freezes == [true, false, true, false])
        #expect(await waitForEvaluation(page, containing: "log-while-frozen"))
        view.close()
    }

    /// The theme (and scale, attributes, glass) a frozen page would get waits too: the page stays
    /// frozen, and the thaw sends the document's state again.
    @Test func aThemeChangeWaitsForTheThawAndIsSentThen() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (view, page, pane, _, _) = try await hiddenBootedPage()
        // The document finished: its state (theme, scale) goes in once before the freeze.
        page.onEvent?(.finished)
        #expect(await waitForEvaluation(page, containing: "cmuxTheme.apply("))
        #expect(view.freezeWhileHidden())
        let themes = evaluations(page, containing: "cmuxTheme.apply(")

        view.applyTheme(force: true)
        view.applyUIScale()
        #expect(page.freezes == [true], "a theme push thawed the hidden page")
        #expect(evaluations(page, containing: "cmuxTheme.apply(") == themes)

        pane.isHidden = false
        let sent: Bool? = await PageTestWait.value("theme after the thaw") { done in
            let check = { [weak page] in
                guard let page else { return }
                if self.evaluations(page, containing: "cmuxTheme.apply(") > themes { done(true) }
            }
            page.onCall = check
            check()
        }
        #expect(sent == true)
        view.close()
    }

    /// A host state script (``PageWebView/evaluateHostState(_:key:)``, an agent page's registry.js)
    /// is a push of the host's state: into an unseen awake page it runs without starting the grace
    /// again, and a frozen page stays frozen and runs the newest script of each key once at the
    /// thaw, in the order of their newest. ``PageWebView/evaluate(_:)`` (work the page must do now)
    /// still thaws.
    @Test func aHostStateScriptThawsNothingAndTheNewestOfEachKeyRunsAtTheThaw() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (view, page, pane, policy, _) = try await hiddenBootedPage()

        let woke = policy.woke
        view.evaluateHostState("window.__state = 'awake'", key: "state")
        #expect(await waitForEvaluation(page, containing: "window.__state = 'awake'"))
        #expect(policy.woke == woke, "a host state script restarted the unseen page's grace")

        #expect(view.freezeWhileHidden())
        view.evaluateHostState("window.__state = 'held-1'", key: "state")
        view.evaluateHostState("window.__other = 'held'", key: "other")
        view.evaluateHostState("window.__state = 'held-2'", key: "state")
        #expect(page.freezes == [true], "a host state script thawed the frozen page")
        #expect(policy.woke == woke)

        pane.isHidden = false
        #expect(await waitForEvaluation(page, containing: "window.__state = 'held-2'"))
        #expect(evaluations(page, containing: "window.__state = 'held-1'") == 0)
        #expect(evaluations(page, containing: "window.__other = 'held'") == 1)
        let order = page.calls.compactMap { $0.params["expression"] as? String }
            .filter { $0.contains("window.__other = 'held'") || $0.contains("window.__state = 'held-2'") }
        #expect(order.count == 2 && order[0].contains("__other") && order[1].contains("held-2"))
        view.close()
    }

    /// A page busy with the host (a call of its own still running) does not freeze: its grace
    /// starts again when the reply went.
    @Test func aPageWithACallRunningDoesNotFreezeUntilTheReplyWent() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = TestProvider()
        let (view, page, _, policy, _) = try await hiddenBootedPage(provider: provider)
        let started: Bool? = await PageTestWait.value("the page's call reached the provider") { done in
            provider.callStarted = { done(true) }
            page.onEvent?(.devTools(FakeChromiumPage.bindingCall([
                "name": PageHostTrust.handlerName, "seq": 2, "body": ["t": "call", "id": 7, "op": "test.wait", "params": [String: Any]()],
            ])))
        }
        #expect(started == true)
        #expect(view.freezeWhileHidden() == false)

        let woke = policy.woke
        let replied: Bool? = await PageTestWait.value("reply") { done in
            page.onCall = { [weak page] in
                if page?.calls.contains(where: { ($0.params["expression"] as? String)?.contains("\(ChromiumPageHostBridge.resolveName)?.(2,") == true }) == true {
                    done(true)
                }
            }
            provider.answer()
        }
        #expect(replied == true)
        #expect(policy.woke > woke)
        #expect(view.freezeWhileHidden())
        view.close()
    }

    /// A page in a window that is covered, minimized or ordered out is unseen: its grace starts and
    /// it may freeze; it thaws when the window is back. Chromium keeps drawing it while it only is
    /// covered (no hide and show on every cover). A freeze hides it in Chromium, and a thaw alone
    /// does not show it again, so the thaw shows it: before, the page came back frozen-hidden
    /// (no frames, `visibilityState` hidden) until a tab switch.
    @Test func aPageInACoveredWindowFreezesAndThawsWhenTheWindowIsBack() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = RecordingFreezePolicy()
        let hosting = FakeChromiumHosting(freezePolicy: policy)
        let view = try makeView(hosting)
        stage.show(view)
        await view.chromiumStart?.value
        let page = try #require(hosting.made.first)
        await boot(view, page)
        #expect(view.freezeWhileHidden() == false) // seen

        let woke = policy.woke
        stage.isOnScreen = false
        #expect(policy.woke == woke + 1)
        #expect(view.chromiumLifecycle == "hidden")
        #expect(view.freezeWhileHidden())

        #expect(Array(page.lifecycle.suffix(2)) == ["hidden", "frozen"])

        stage.isOnScreen = true
        #expect(Array(page.lifecycle.suffix(2)) == ["thawed", "shown"])
        #expect(page.isDrawing, "the page came back from its freeze hidden in Chromium")
        #expect(!view.isChromiumFrozen)
        #expect(policy.noLongerHidden == 2)
        view.close()
    }
}
