import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextHibernation
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// Page tab discards (`memoryDiscardInternalPages`): a page tab hidden past its
/// provider's policy lets its view go through the content lifecycle (`hibernate` and its
/// `release` effect) and keeps the tab; its next show makes the view again (`restore`), under its
/// last picture, with its route and scroll put back. A keep reason holds it, a provider that
/// declares no policy is never discarded, and one one-shot deadline on the scheduler's one clock
/// says when to look again.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct InternalPageDiscardTests {
    @Test func aHiddenWebPagePastItsPolicyLetsItsPageWebViewGoAndGetsItsDocumentScrollBack() async throws {
        let web = try WebRig()
        defer { web.close() }
        let provider = WebPage { web.makePage() }
        let rig = Rig(provider)
        weak var page: PageWebView?
        do {
            let view = try #require(rig.pages.view(for: rig.key))
            let shown = try #require(view.content as? PageWebView)
            page = shown
            view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
            view.layoutSubtreeIfNeeded()
            await shown.chromiumStart?.value
            shown.notePainted()
            rig.show()
            #expect(rig.cache.phase(of: rig.key) == .mountedVisible)
            // The person scrolled the document to 700 (the fake engine answers the read).
            web.scrollY = 700
            rig.hide()
        }
        #expect(rig.cache.phase(of: rig.key) == .mountedHidden)
        #expect(rig.discards.nextCheck == 600, "the policy's 10 minutes")

        rig.advance(601)
        rig.discards.replan()
        await rig.discards.settled()

        #expect(rig.cache.phase(of: rig.key) == .hibernated)
        #expect(rig.pages.existingView(rig.key) == nil)
        #expect(rig.pages.isDiscarded(rig.key))
        #expect(page == nil, "the discarded tab's PageWebView is still alive")
        #expect(provider.discarded == [rig.key])
        #expect(web.hosting.made.first?.closed == true, "the provider closed its page's engine session")
        #expect(rig.discards.discardedCount == 1)
        #expect(rig.pages.stripItem(rig.key).title == provider.title, "the tab keeps its title")

        // Shown again: the pane makes the view first, then presents it.
        let rebuilt = try #require(rig.pages.view(for: rig.key))
        let rebuiltPage = try #require(rebuilt.content as? PageWebView)
        #expect(rebuiltPage !== page)
        #expect(rebuilt.picture != nil, "the rebuilt page shows its last picture until it paints")
        #expect(!rebuilt.awaitsFirstPaint, "the picture is its first frame: the pane does not hold the old tab")
        rig.show()
        #expect(rig.cache.phase(of: rig.key) == .mountedVisible)
        #expect(provider.made == 2)
        rebuilt.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        rebuilt.layoutSubtreeIfNeeded()
        await rebuiltPage.chromiumStart?.value
        let engine = try #require(web.hosting.made.last)
        #expect(!web.scrolled(engine), "scrolled before the rebuilt document painted")
        #expect(rebuilt.restoring == nil, "restored before the rebuilt document painted")
        // The rebuilt document paints: its scroll goes back, then the picture leaves.
        rebuiltPage.notePainted()
        await rebuilt.restoring?.value
        #expect(web.scrolled(engine), "the rebuilt document never scrolled back to 700")
        #expect(rebuilt.picture == nil, "the picture stayed over the page that drew its restored state")
    }

    @Test func aHiddenPaintedPageIsPicturedAtItsHideAndANeverPageIsNot() async throws {
        let web = try WebRig()
        defer { web.close() }
        let provider = WebPage { web.makePage() }
        let rig = Rig(provider)
        let view = try #require(rig.pages.view(for: rig.key))
        let page = try #require(view.content as? PageWebView)
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        view.layoutSubtreeIfNeeded()
        await page.chromiumStart?.value
        page.notePainted()
        rig.show()
        rig.hide()
        await rig.pages.discardRecords.pictures[rig.key]?.task?.value
        #expect(rig.cache.internalPagePictures.image(for: rig.key) != nil, "the hide took no picture of the painted page")
        let captures = { web.hosting.made.flatMap(\.calls).filter { $0.method == "Page.captureScreenshot" }.count }
        #expect(captures() == 1)

        // Hidden again with nothing new to show: the picture it has is current.
        rig.show()
        rig.hide()
        #expect(captures() == 1, "a plain switch pictured an unchanged page again")

        // A page that is never discarded pays for no picture.
        provider.policy = .never
        rig.cache.internalPagePictures.remove(rig.key)
        rig.show()
        rig.hide()
        #expect(captures() == 1, "a page that is never discarded was pictured at its hide")
    }

    @Test func theDefaultViewStateKeepsANativePagesScroll() async throws {
        let rig = Rig(DefaultStatePage { Self.scrollingContent() })
        do {
            let view = try #require(rig.pages.view(for: rig.key))
            view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
            view.layoutSubtreeIfNeeded()
            let scroll = try #require(view.content.firstScrollView)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 500))
            scroll.reflectScrolledClipView(scroll.contentView)
            rig.show()
            rig.hide()
        }
        rig.advance(601)
        rig.discards.replan()
        await rig.discards.settled()
        #expect(rig.pages.existingView(rig.key) == nil)

        let rebuilt = try #require(rig.pages.view(for: rig.key))
        rebuilt.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        rebuilt.layoutSubtreeIfNeeded()
        await rebuilt.restoring?.value
        let scroll = try #require(rebuilt.content.firstScrollView)
        #expect(scroll.documentVisibleRect.origin.y == 500)
        #expect(rebuilt.picture == nil, "native content draws at once: no cover")
    }

    @Test func aProviderThatDeclaresNoPolicyIsNeverDiscarded() async throws {
        // Settings' pattern: one cached page, given again whenever it has no superview, and no
        // teardown of its own. Discarding it would hand back an inert page; it must stay.
        let provider = CachingPage()
        let rig = Rig(provider)
        let view = try #require(rig.pages.view(for: rig.key))
        rig.show()
        rig.hide()
        rig.advance(3_600)
        rig.discards.replan()
        await rig.discards.settled()
        rig.discards.update(pressure: .critical)
        await rig.discards.settled()
        #expect(rig.pages.existingView(rig.key) === view, "a provider with no policy of its own lost its view")
        #expect(rig.cache.phase(of: rig.key) == .mountedHidden)
        #expect(!rig.discards.hasDeadline, "a page that never goes needs no deadline")
        #expect(provider.made == 1)
    }

    @Test func aRebuiltPageShowsTheRouteItShowedBeforeItsDiscard() async throws {
        // Workspace Todo's pattern: the route is read once, at makeView, then the window's current one.
        let provider = RoutePage()
        let rig = Rig(provider)
        provider.pending[rig.key] = "workspace-A"
        _ = try #require(rig.pages.view(for: rig.key))
        rig.show()
        rig.hide()
        provider.current = "workspace-B"
        rig.advance(601)
        rig.discards.replan()
        await rig.discards.settled()
        #expect(rig.pages.existingView(rig.key) == nil)

        _ = try #require(rig.pages.view(for: rig.key))
        #expect(provider.shown == ["workspace-A", "workspace-A"], "the rebuilt page lost its route")
        #expect(provider.route(for: rig.key) == "workspace-A")
    }

    @Test func aKeepReasonHoldsTheViewAndIsAskedAgainOnePolicyTimeLater() async throws {
        let provider = DefaultStatePage { NSView() }
        let rig = Rig(provider)
        _ = try #require(rig.pages.view(for: rig.key))
        provider.keep = [.unsavedEdits]
        rig.show()
        rig.hide()
        rig.advance(601)
        rig.discards.replan()
        await rig.discards.settled()
        #expect(rig.pages.existingView(rig.key) != nil, "a page with unsaved edits lost its view")
        #expect(rig.cache.phase(of: rig.key) == .mountedHidden)
        #expect(rig.discards.exemptions[rig.key] == .unsavedEdits)
        #expect(rig.discards.nextCheck == 600)
        #expect(rig.discards.hasDeadline)

        provider.keep = []
        rig.advance(600)
        rig.discards.replan()
        await rig.discards.settled()
        #expect(rig.pages.existingView(rig.key) == nil)
    }

    @Test func oneOneShotDeadlineAndNoneForANeverPolicyOrAShownPage() throws {
        let provider = DefaultStatePage { NSView() }
        let rig = Rig(provider)
        _ = try #require(rig.pages.view(for: rig.key))
        rig.show()
        #expect(!rig.discards.hasDeadline, "a shown page needs no deadline")
        rig.hide()
        #expect(rig.discards.hasDeadline)
        #expect(rig.discards.nextCheck == 600)
        rig.advance(120)
        rig.discards.replan()
        #expect(rig.discards.nextCheck == 480, "one deadline, at the policy's end")
        rig.show()
        #expect(!rig.discards.hasDeadline)
        #expect(rig.discards.nextCheck == nil)

        provider.policy = .never
        rig.hide()
        #expect(!rig.discards.hasDeadline, "a never policy has no deadline")
    }

    @Test func theDeadlineAloneDiscardsAPageHiddenPastItsPolicy() async throws {
        let clock = ManualClock()
        let rig = Rig(DefaultStatePage { NSView() }, clock: clock)
        _ = try #require(rig.pages.view(for: rig.key))
        rig.show()
        rig.hide()
        try await clock.waitForSleeper()
        // Only the clock moves: no replan by hand. The deadline fires and the page goes.
        let waiter = Waiter()
        let discarded = await waiter.wait(until: { rig.pages.existingView(rig.key) == nil },
                                          signal: { rig.discards.onDiscard = $0 }, then: { clock.advance(by: .seconds(601)) })
        #expect(discarded, "the deadline fired and the page hidden past its policy stayed")
        #expect(rig.cache.phase(of: rig.key) == .hibernated)
    }

    @Test func criticalPressureDiscardsAPageHiddenTenSecondsAndWaitsForOneHiddenLess() async throws {
        let clock = ManualClock()
        let rig = Rig(DefaultStatePage { NSView() }, clock: clock)
        _ = try #require(rig.pages.view(for: rig.key))
        rig.show()
        rig.hide()
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(4))
        rig.discards.update(pressure: .critical)
        await rig.discards.settled()
        #expect(rig.pages.existingView(rig.key) != nil, "a page hidden 4 s went at critical pressure")
        #expect(rig.discards.nextCheck == 6, "looked at again once it is hidden 10 s")
        try await clock.waitForSleeper()

        let discarded = await Waiter().wait(until: { rig.pages.existingView(rig.key) == nil },
                                            signal: { rig.discards.onDiscard = $0 }, then: { clock.advance(by: .seconds(7)) })
        #expect(discarded, "a page hidden 11 s, far less than its 10 minute policy, stayed at critical pressure")
    }

    @Test func aShowWhileThePageSavesItsStateKeepsItsView() async throws {
        let provider = ReportingPage { NSView() }
        let rig = Rig(provider)
        _ = try #require(rig.pages.view(for: rig.key))
        rig.show()
        rig.hide()
        // The tab shows again while its state is read: the lifecycle's generation moved.
        provider.onSave = { [rig] in rig.show() }
        rig.advance(601)
        rig.discards.replan()
        await rig.discards.settled()
        #expect(rig.pages.existingView(rig.key) != nil, "a late preparation let a shown page go")
        #expect(rig.cache.phase(of: rig.key) == .mountedVisible)
        #expect(rig.discards.discardedCount == 0)
    }

    @Test func withTheFeatureOffNothingIsDiscarded() async throws {
        let rig = Rig(DefaultStatePage { NSView() }, discarding: false)
        _ = try #require(rig.pages.view(for: rig.key))
        rig.show()
        rig.hide()
        rig.advance(3_600)
        rig.discards.replan()
        await rig.discards.settled()
        #expect(rig.cache.contentOwners.isEmpty)
        #expect(rig.pages.discards == nil)
        #expect(!rig.discards.hasDeadline)
        #expect(rig.pages.existingView(rig.key) != nil)
    }

    // MARK: Rig

    @MainActor final class Rig {
        let services: AppServices
        let clock: ManualClock
        let discards: ContentDiscardScheduler
        let pane = Pane()
        let key: String
        var cache: TabContentCache { services.cache }
        var pages: InternalPageTabStore { services.pages }

        /// `clock` is the scheduler's one clock; `discarding` false is the feature off (nothing wired).
        init(_ provider: any InternalPageProvider, clock: ManualClock = ManualClock(), discarding: Bool = true) {
            _ = NSApplication.shared
            services = AppServices(environment: AppEnvironment.current([:]))
            self.clock = clock
            discards = ContentDiscardScheduler(kind: .internalPage, clock: clock)
            services.pages.register(provider)
            // What AppMemoryConsumers does with `memoryDiscardInternalPages` on.
            if discarding { services.pages.enableDiscards(discards, on: services.cache) }
            key = services.pages.open(provider.page, in: "pane-discard-test", of: DaemonStore())
        }

        func show() { cache.present(key, by: pane, presence: .visible) }
        func hide() { cache.withdraw(key, by: pane) }
        func advance(_ seconds: Int64) { clock.advance(by: .seconds(seconds)) }
    }

    @MainActor final class Pane: SurfacePresenter {
        func surfaceWasDisplaced(_ key: String) {}
    }

    /// Waits, bounded on the wall clock, until `check` holds; `signal` installs the callback that
    /// says something changed. No polling: the check runs on each signal.
    @MainActor final class Waiter {
        private var resume: ((Bool) -> Void)?
        private var check: () -> Bool = { false }
        private let timer = DemandTimer(owner: "InternalPageDiscardTests.Waiter", ledger: WakeupLedger())

        func wait(within limit: Duration = .seconds(10), until check: @escaping () -> Bool,
                  signal: (@escaping () -> Void) -> Void, then start: () -> Void = {}) async -> Bool {
            self.check = check
            signal { [weak self] in self?.finishIfDone() }
            start()
            if check() { return true }
            return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                resume = { continuation.resume(returning: $0) }
                timer.schedule(after: limit) { @MainActor [weak self] in self?.finish(self?.check() ?? false) }
            }
        }

        private func finishIfDone() {
            if check() { finish(true) }
        }

        private func finish(_ value: Bool) {
            timer.cancel()
            resume?(value)
            resume = nil
        }
    }

    /// Pages in a fake Chromium host: the engine answers the document scroll and a picture, and
    /// records the calls the app makes.
    @MainActor final class WebRig {
        let hosting = FakeChromiumHosting()
        let folder: URL
        /// The document scroll the engine reports.
        var scrollY = 0
        /// Never fired: the pages' Chromium fallback never runs out.
        private let pageDeadlines = MainDeadlineRig()

        init() throws {
            folder = FileManager.default.temporaryDirectory.appending(path: "page-discard-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("<html><body style='height:4000px'></body></html>".utf8).write(to: folder.appending(path: "index.html"))
            let png = Self.png()
            hosting.onMade = { [weak self] page in
                page.answer = { method, params in
                    if method == "Page.captureScreenshot" { return #"{"data":"\#(png)"}"# }
                    guard method == "Runtime.evaluate", let expression = params["expression"] as? String,
                          expression.contains("window.scrollY"), !expression.contains("scrollTo") else { return nil }
                    return #"{"result":{"type":"object","value":[0,\#(self?.scrollY ?? 0)]}}"#
                }
            }
        }

        func makePage() -> NSView {
            guard let page = PageWebView(descriptor: PageDescriptor(id: "test.discard", resource: "discard", processGroup: .solo, namespaces: []),
                                         root: folder, routes: [], chromium: hosting) else { return NSView() }
            // The engine's no-message deadline never runs out here.
            page.chromiumDeadlines = pageDeadlines.deadlines
            return page
        }

        /// Whether the app scrolled `engine`'s document back to 700.
        func scrolled(_ engine: FakeChromiumPage) -> Bool {
            engine.calls.contains { call in
                guard call.method == "Runtime.evaluate", let expression = call.params["expression"] as? String else { return false }
                return expression.contains("scrollTo") && expression.contains("700")
            }
        }

        func close() { try? FileManager.default.removeItem(at: folder) }

        private static func png() -> String {
            let image = NSImage(size: NSSize(width: 4, height: 3))
            image.lockFocus()
            NSColor.red.setFill()
            NSRect(x: 0, y: 0, width: 4, height: 3).fill()
            image.unlockFocus()
            let data = image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
            return data?.base64EncodedString() ?? ""
        }
    }

    /// What the test pages share; the subclasses differ only in the view state they keep.
    @MainActor class TestPage {
        let page = InternalPageID(rawValue: "discard-test")
        let title = "Discard test"
        let symbol = "doc"
        var policy = ContentDiscardPolicy.standard
        var keep: [CannotDiscardReason] = []
        var discarded: [String] = []
        var made = 0
        private let make: () -> NSView

        init(_ make: @escaping () -> NSView) {
            self.make = make
        }

        func makeView(for key: String, in window: WindowController?) -> NSView {
            made += 1
            return make()
        }

        func discardPolicy(for key: String) -> ContentDiscardPolicy { policy }
        func keepReasons(for key: String) -> [CannotDiscardReason] { keep }
        func viewDiscarded(_ key: String) { discarded.append(key) }
    }

    /// A page on the provider's default view state.
    @MainActor final class DefaultStatePage: TestPage, InternalPageProvider {}

    /// A page that runs `onSave` while its state is read.
    @MainActor final class ReportingPage: TestPage, InternalPageProvider {
        /// Runs while the state is read (a show in the middle of a discard).
        var onSave: (() -> Void)?

        func saveViewState(for key: String, content: NSView) async -> ContentViewState {
            onSave?()
            return ContentViewState()
        }
    }

    /// A web page that owns its page: its teardown closes the page's engine session and drops it.
    @MainActor final class WebPage: TestPage, InternalPageProvider {
        private var pages: [String: PageWebView] = [:]

        override func makeView(for key: String, in window: WindowController?) -> NSView {
            let view = super.makeView(for: key, in: window)
            pages[key] = view as? PageWebView
            return view
        }

        override func viewDiscarded(_ key: String) {
            super.viewDiscarded(key)
            pages.removeValue(forKey: key)?.close()
        }

        func tabClosed(_ key: String) { pages.removeValue(forKey: key)?.close() }
    }

    /// Settings' pattern: one cached view handed out again whenever it has no superview; no policy.
    @MainActor final class CachingPage: InternalPageProvider {
        let page = InternalPageID(rawValue: "discard-test-caching")
        let title = "Caching"
        let symbol = "gear"
        var made = 0
        private var cached: NSView?

        func makeView(for key: String, in window: WindowController?) -> NSView {
            if let cached, cached.superview == nil { return cached }
            made += 1
            let view = NSView()
            if cached == nil { cached = view }
            return view
        }

        func tabClosed(_ key: String) {}
    }

    /// Workspace Todo's pattern: the route given before its view is read once; later views show the
    /// window's current one.
    @MainActor final class RoutePage: TestPage, InternalPageProvider {
        var pending: [String: String] = [:]
        var routes: [String: String] = [:]
        var current = "workspace-current"
        var shown: [String] = []

        init() { super.init { NSView() } }

        override func makeView(for key: String, in window: WindowController?) -> NSView {
            let route = pending.removeValue(forKey: key) ?? current
            routes[key] = route
            shown.append(route)
            return super.makeView(for: key, in: window)
        }

        func route(for key: String) -> String? { routes[key] }
        func restore(_ route: String, for key: String) { pending[key] = route }
    }

    private static func scrollingContent() -> NSView {
        let scroll = NSScrollView()
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 2000))
        scroll.hasVerticalScroller = true
        return scroll
    }
}
