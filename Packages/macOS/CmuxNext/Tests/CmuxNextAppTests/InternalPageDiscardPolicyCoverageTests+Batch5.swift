import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDevices
@testable import CmuxNextFeed
import CmuxNextHibernation
@testable import CmuxNextMacScreen
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
@testable import CmuxNextPhone
import CmuxNextSettings
import CmuxNextWakeupsTestSupport
import Foundation
import Testing
import CmuxNextWakeups

/// Page policies batch 5: the App Store, CodeRouter, Cloud, Mobile Pairing, Mac
/// Screen, Phone and Inbox pages each declare when their hidden tab's view may go, and a discard
/// closes the page it drops. Mobile Pairing keeps its page while a step the person started runs,
/// Cloud while a change the person approved runs, Mac Screen and Phone go once their stream
/// stopped for a while and keep what they showed; the App Store and Cloud come back on the place
/// their page showed.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct InternalPageDiscardPolicyCoverageTestsBatch5 {
    typealias Rig = InternalPageDiscardTests.Rig
    typealias WebRig = InternalPageDiscardTests.WebRig

    // MARK: Policies

    /// Each page of the batch, as the app registers it, declares its policy; a React page tab that
    /// declares none (Stats, Chief Usage, Channels until their own batch) is never discarded.
    @Test func eachPageOfTheBatchRegistersItsOwnPolicy() throws {
        let services = MachineIconTests.services()
        AppActions.bind(services)
        let expected: [(InternalPageID, ContentDiscardPolicy)] = [
            (.appStore, .standard), (.cloud, .standard), (.mobilePairing, .standard), (.inbox, .standard),
            (.macScreen, .afterHidden(.seconds(20))), (.phone, .afterHidden(.seconds(20))),
        ]
        for (id, policy) in expected {
            let provider = try #require(services.pages.provider(id), "\(id.rawValue) is not registered")
            #expect(provider.discardPolicy(for: "batch5") == policy, "\(id.rawValue)")
        }
        #expect(CodeRouterPageTab.make(services).discardPolicy(for: "batch5") == .standard)
        let undeclared = WebPageTab(.stats, symbol: "chart.bar.xaxis", title: "Stats") { nil }
        #expect(undeclared.discardPolicy(for: "batch5") == .never, "a page tab that chose no policy became discardable")
    }

    // MARK: CodeRouter (WebPageTab)

    @Test func aDiscardedCodeRouterTabClosesItsPageAndMakesANewOne() async throws {
        let web = try WebRig()
        defer { web.close() }
        let deadlineRig = MainDeadlineRig() // never fired: the Chromium fallback never runs out
        let tab = WebPageTab(.coderouter, symbol: "arrow.triangle.branch", title: "CodeRouter",
                             discardPolicy: CodeRouterPageTab.hiddenPolicy) { Self.testPage(web, route: nil, deadlines: deadlineRig.deadlines) }
        let rig = Rig(tab)
        let discarded = try await Self.discard(rig)
        #expect(!tab.hasPage(rig.key))
        #expect(web.hosting.made.first?.closed == true, "the discarded page's engine session outlived it")
        #expect(await Self.isClosed(discarded), "the discarded page's routes still answer")

        let rebuilt = try #require(rig.pages.view(for: rig.key)?.content as? PageWebView)
        #expect(rebuilt !== discarded)
        #expect(tab.hasPage(rig.key))
        rig.pages.close(rig.key)
        #expect(!tab.hasPage(rig.key))
    }

    // MARK: App Store

    @Test func aDiscardedAppStoreTabComesBackOnThePlaceItsPageShowed() async throws {
        let web = try WebRig()
        defer { web.close() }
        Self.answerFragment(web, "#/installed") // the person moved there with the page's own links
        let deadlineRig = MainDeadlineRig() // never fired: the Chromium fallback never runs out
        let services = MachineIconTests.services()
        var routes: [String] = []
        let apps = AppsService(services: services) { route in
            routes.append(route)
            return Self.testPage(web, route: route, deadlines: deadlineRig.deadlines)
        }
        let rig = Rig(apps)
        let discarded = try await Self.discard(rig)
        #expect(discarded.route == "#/discover", "the host asked for Discover")
        #expect(web.hosting.made.first?.closed == true, "the discarded page's engine session outlived it")
        #expect(await Self.isClosed(discarded))

        let rebuilt = try #require(rig.pages.view(for: rig.key)?.content as? PageWebView)
        #expect(routes == ["#/discover", "#/installed"], "the rebuilt page opened on the host's last route, not the page's")
        #expect(rebuilt.route == "#/installed")
        rig.pages.close(rig.key)
    }

    // MARK: Cloud

    @Test func aDiscardedCloudTabComesBackOnItsPlaceAndScroll() async throws {
        let web = try WebRig()
        defer { web.close() }
        Self.answerFragment(web, "#/get")
        web.scrollY = 700 // the person scrolled the machine list
        let deadlineRig = MainDeadlineRig() // never fired: the Chromium fallback never runs out
        let services = MachineIconTests.services()
        var routes: [String?] = []
        let cloud = CloudPageService(services: services) { route in
            routes.append(route)
            return Self.testPage(web, route: route, deadlines: deadlineRig.deadlines).map { (page: $0, provider: CloudPageProvider(op: { _, _, _, _ in .object([:]) })) }
        }
        let rig = Rig(cloud)
        let discarded = try await Self.discard(rig)
        services.webUI.retirer.closeRetired() // the engine page ends at the retirer's deadline
        #expect(web.hosting.made.first?.closed == true, "the discarded page's engine session outlived it")
        #expect(await Self.isClosed(discarded))

        let view = try #require(rig.pages.view(for: rig.key))
        let rebuilt = try #require(view.content as? PageWebView)
        #expect(routes == [nil, "#/get"])
        rig.show()
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        view.layoutSubtreeIfNeeded()
        await rebuilt.chromiumStart?.value
        rebuilt.notePainted()
        await view.restoring?.value
        let engine = try #require(web.hosting.made.last)
        #expect(web.scrolled(engine), "the machine list did not scroll back")
        rig.pages.close(rig.key)
        services.webUI.retirer.closeRetired()
        #expect(engine.closed, "a closed Cloud tab left its page open")
    }

    @Test func aCloudChangeThePersonApprovedCountsUntilItAnswers() async throws {
        let (gate, open) = AsyncStream<Void>.makeStream()
        let (entered, enter) = AsyncStream<Void>.makeStream()
        let provider = CloudPageProvider(op: { _, _, _, _ in
            enter.yield()
            for await _ in gate { break }
            return .object([:])
        })
        let create = Task { try await provider.call("cmux.cloud.machine.create", params: .object([:]), context: Self.confirmed) }
        var steps = entered.makeAsyncIterator()
        _ = await steps.next()
        #expect(provider.confirmedCallsInFlight == 1, "a create waiting on the server keeps the Cloud page")
        open.yield()
        _ = try await create.value
        #expect(provider.confirmedCallsInFlight == 0)

        let read = Task { try await provider.call("cmux.cloud.machine.list", params: .object([:]), context: Self.page) }
        _ = await steps.next()
        #expect(provider.confirmedCallsInFlight == 0, "a read the page made keeps nothing")
        open.yield()
        _ = try await read.value
        open.finish()
    }

    // MARK: Mobile Pairing

    /// The page renews its code by itself while hidden, so a code shown keeps nothing; a discard
    /// ends the page's `changes` watch with its routes.
    @Test func aMobilePairingPageGoesWithItsWatch() async throws {
        let web = try WebRig()
        defer { web.close() }
        let services = MachineIconTests.services()
        var opened: PageWebView?
        let pairing = MobilePairingPageService(services: services) { request in
            opened = PageWebView(descriptor: Self.pairingDescriptor, root: web.folder, routes: request.routes, chromium: nil, deadlines: .testing())
            return opened
        }
        let key = "mobile-pairing-batch5"
        _ = pairing.makeView(for: key, in: nil)
        let page = try #require(opened)
        let watch = await page.router.handle(Self.subscribe(MobilePairingPageProvider.changesStream))
        #expect(watch["t"]?.stringValue == "ok", "the page could not watch the pairing status")
        #expect(pairing.keepReasons(for: key).isEmpty, "a code shown in a hidden tab keeps the page")

        pairing.viewDiscarded(key)
        #expect(await Self.isClosed(page, stream: MobilePairingPageProvider.changesStream),
                "the discarded page's routes and watch outlived it")
        #expect(pairing.keepReasons(for: key).isEmpty)
        pairing.tabClosed(key)
    }

    // MARK: Mac Screen

    @Test func aDiscardedMacScreenTabKeepsItsDeviceAndAsksForTheSameScopeWhenShown() throws {
        let pages = Self.macScreenPages()
        let key = "mac-screen-batch5"
        pages.prepare(key, record: MacScreenRecord(deviceID: Self.deviceID), byPerson: false)
        let first = pages.makeView(for: key)
        let hub = try #require(pages.tab(key)?.pane?.model.hub)
        hub.phase = .waitingForApproval(sessionID: "s1", scope: .full)
        #expect(pages.isRequesting(key), "a request waiting on the other Mac keeps the tab's view")
        hub.phase = .streaming(sessionID: "s1", scope: .view)
        #expect(!pages.isRequesting(key))

        pages.viewDiscarded(key)
        #expect(pages.tab(key) == nil, "the session and its view outlived the discard")
        #expect(pages.route(for: key) == "device:\(Self.deviceID)", "the tab forgot its device")
        #expect(pages.pendingScopes[Self.deviceID] == nil, "the discarded tab's scope went to the home page's choices")

        let second = pages.makeView(for: key)
        #expect(second !== first)
        #expect(pages.tab(key)?.pane?.model.hub?.resumeScope == .view, "showing the tab again asks for the scope it streamed")
        pages.tabClosed(key)
    }

    /// A discarded tab's scope is its own: another tab on the same device, opened with no scope
    /// chosen, waits at Connect, and a closed tab's scope goes with it.
    @Test func aDiscardedMacScreenTabsScopeStaysWithThatTab() throws {
        let pages = Self.macScreenPages()
        let streamed = "mac-screen-streamed-batch5"
        pages.prepare(streamed, record: MacScreenRecord(deviceID: Self.deviceID), byPerson: false)
        _ = pages.makeView(for: streamed)
        let hub = try #require(pages.tab(streamed)?.pane?.model.hub)
        hub.phase = .streaming(sessionID: "s1", scope: .full)
        pages.viewDiscarded(streamed)

        let other = "mac-screen-other-batch5"
        pages.prepare(other, record: MacScreenRecord(deviceID: Self.deviceID), byPerson: true)
        _ = pages.makeView(for: other)
        #expect(pages.tab(other)?.pane?.model.hub?.resumeScope == nil, "a tab nobody chose a scope for asked for Full Control")
        pages.tabClosed(other)

        pages.tabClosed(streamed)
        #expect(pages.resumeScopes[streamed] == nil, "a closed tab's scope outlived it")
        pages.prepare(streamed, record: MacScreenRecord(deviceID: Self.deviceID), byPerson: true)
        _ = pages.makeView(for: streamed)
        #expect(pages.tab(streamed)?.pane?.model.hub?.resumeScope == nil, "a new tab took a closed tab's scope")
        pages.tabClosed(streamed)
    }

    @Test func aDiscardedMacScreenHomeTabStaysHome() {
        let pages = Self.macScreenPages()
        let key = "mac-screen-home-batch5"
        pages.prepare(key, record: MacScreenRecord(macID: nil), byPerson: true)
        _ = pages.makeView(for: key)
        pages.viewDiscarded(key)
        #expect(pages.route(for: key) == "home")
        _ = pages.makeView(for: key)
        #expect(pages.tab(key)?.pane == nil, "the home page came back as a screen")
        pages.tabClosed(key)
    }

    // MARK: Phone

    @Test func aDiscardedPhoneTabShowsTheSamePhoneAndLeavesTheNextTabsPhone() throws {
        let tab = PhonePageTab(phones: Self.phones(), mainWork: linklessMainWork(), nodes: { VisibilityNode(root: "test.phone.\($0)", own: .visible) })
        let key = "phone-batch5"
        #expect(PhonePageTab.hiddenPolicy == .afterHidden(.seconds(20)),
                "a phone tab switched away from and back was rebuilt, running xcrun on the show")
        tab.restore("sim:AAAA", for: key)
        let first = tab.makeView(for: key, in: nil)
        #expect(tab.keepReasons(for: key).isEmpty)
        let view = try #require(first as? PhoneTabView)
        view.notesField.stringValue = "the cart is empty"
        #expect(tab.keepReasons(for: key) == [.unsavedEdits], "notes typed for a recording live only in the view")
        view.notesField.stringValue = ""

        tab.viewDiscarded(key)
        #expect(tab.route(for: key) == "sim:AAAA", "the tab forgot its phone")
        #expect(tab.keepReasons(for: key).isEmpty)
        // Rebuilt while a `phone.show` for another phone runs: the tab keeps its own.
        let rebuilt = tab.opens.during(PhoneDeviceID("sim:BBBB")) { tab.makeView(for: key, in: nil) }
        let second = try #require(rebuilt as? PhoneTabView)
        #expect(second !== view)
        #expect(second.route == "sim:AAAA", "a rebuilt tab took the phone another show asked for")
        tab.tabClosed(key)
    }

    // MARK: Inbox

    @Test func theInboxKeepsItsViewWhileABasketReplyIsTypedOrSent() throws {
        let model = FeedModel(source: MockFeedSource())
        model.replaceReports([FeedReport(id: "r1", sender: "host/alpha", body: "a report", createdAt: Date(timeIntervalSince1970: 1_000))])
        let host = FeedHostView(model: model, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        #expect(!host.hasTypedReply && !host.isSendingReply)
        let basket = ReportsBasketView(model: model, mainWork: MainWorkScheduler(budget: MainFrameBudget()), onReply: { _ in true })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        host.addSubview(basket)
        basket.frame = host.bounds
        basket.layoutSubtreeIfNeeded()
        let detail = try #require(basket.detail)

        detail.field.stringValue = "on it"
        detail.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: detail.field))
        #expect(host.hasTypedReply, "a reply typed in the basket lives only in its view")
        basket.send()
        #expect(host.isSendingReply, "a reply on its way keeps the basket that retries it")
    }

    // MARK: Rig

    static let deviceID = "0b6c1a2e-3d4f-4a5b-8c9d-aabbccddeeff"
    static let page = PageCallContext(page: PageDescriptor.cloud.id)
    static let confirmed = PageCallContext(page: PageDescriptor.cloud.id, origin: "user", confirmed: true)
    /// The Mobile Pairing page's namespace on a test page id (a first-party id is served only
    /// from its bundled root, which `swift test` does not build).
    static let pairingDescriptor = PageDescriptor(id: "test.mobile-pairing", resource: "discard", processGroup: .privileged, namespaces: ["cmux.mobilePairing."])

    /// A page in `web`'s fake Chromium host, opened on `route`.
    static func testPage(_ web: WebRig, route: String?, deadlines: MainDeadlineScheduler) -> PageWebView? {
        let page = PageWebView(descriptor: PageDescriptor(id: "test.discard", resource: "discard", processGroup: .solo, namespaces: []),
                               root: web.folder, routes: [], route: route, chromium: web.hosting, deadlines: .testing())
        // The engine's no-message deadline never runs out here.
        page?.chromiumDeadlines = deadlines
        return page
    }

    /// Makes `web`'s pages answer `fragment` for `window.location.hash` (and the document scroll).
    static func answerFragment(_ web: WebRig, _ fragment: String) {
        let made = web.hosting.onMade
        web.hosting.onMade = { page in
            made?(page)
            let scroll = page.answer
            page.answer = { method, params in
                if method == "Runtime.evaluate", let expression = params["expression"] as? String, expression.contains("location.hash") {
                    return #"{"result":{"type":"string","value":"\#(fragment)"}}"#
                }
                return scroll?(method, params)
            }
        }
    }

    /// Shows `rig`'s tab with a painted page, hides it past its policy and lets the discard run;
    /// returns the page that went.
    static func discard(_ rig: Rig) async throws -> PageWebView {
        let view = try #require(rig.pages.view(for: rig.key))
        let shown = try #require(view.content as? PageWebView)
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        view.layoutSubtreeIfNeeded()
        await shown.chromiumStart?.value
        shown.documentFinished() // its document loaded: the fragment read asks the document
        shown.notePainted()
        rig.show()
        rig.hide()
        rig.advance(601)
        rig.discards.replan()
        await rig.discards.settled()
        #expect(rig.cache.phase(of: rig.key) == .hibernated, "the hidden tab was not discarded")
        #expect(rig.pages.existingView(rig.key) == nil)
        return shown
    }

    static func subscribe(_ stream: String) -> CmuxNextSettings.JSONValue {
        ["t": .string("sub"), "id": .number(1), "stream": .string(stream)]
    }

    /// Whether `page`'s routes were closed: a new watch is refused.
    static func isClosed(_ page: PageWebView, stream: String = PageNativeOp.pageCommand) async -> Bool {
        let reply = await page.router.handle(subscribe(stream))
        return reply["t"]?.stringValue == "err" && reply["code"]?.stringValue == PageError.closed.code
    }

    static func macScreenPages() -> MacScreenPages {
        let file = FileManager.default.temporaryDirectory.appending(path: "mac-screen-\(UUID().uuidString)/mac-screen.json")
        return MacScreenPages(store: MacScreenStore(file: file, runner: BackgroundWork(label: "test.mac-screen")), deadlines: linklessDeadlines(), appEvents: AppEvents(center: NotificationCenter()))
    }

    static func phones() -> PhoneService {
        let folder = FileManager.default.temporaryDirectory.appending(path: "phone-batch5-\(UUID().uuidString)", directoryHint: .isDirectory)
        return PhoneService(backend: XcodePhoneBackend(runner: NoXcrun()), recordings: folder.appending(path: "recordings"),
                            scratch: folder.appending(path: "scratch"))
    }

    /// A Mac with no Xcode: every command fails, so a phone tab shows its error and nothing runs.
    struct NoXcrun: PhoneCommandRunning {
        struct Missing: Error {}

        func run(_ arguments: [String], stdin: Data?, deadline: Duration) async throws -> PhoneCommandResult { throw Missing() }
        func start(_ arguments: [String], stdoutFile: URL?) async throws -> any PhoneRunningCommand { throw Missing() }
    }
}
