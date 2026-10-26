import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDevices
@testable import CmuxNextFeed
import CmuxNextHibernation
@testable import CmuxNextMacScreen
import CmuxNextPages
@testable import CmuxNextPhone
import Foundation
import Testing

/// Page policies batch 5 (p07-memory-028): the App Store, CodeRouter, Cloud, Mobile Pairing, Mac
/// Screen, Phone and Inbox pages each declare when their hidden tab's view may go. Mobile Pairing
/// keeps its page while its code works, Cloud while a change the person approved runs, Mac Screen
/// and Phone go when their stream stops and keep what they showed.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct InternalPageDiscardPolicyCoverageTestsBatch5 {
    @Test func everyPageOfTheBatchDeclaresItsPolicy() throws {
        let declaration = "func discardPolicy(for key: String) -> ContentDiscardPolicy"
        let files = [
            "Apps/AppsService.swift", "Cloud/CloudPageService.swift", "Pages/MobilePairing/MobilePairingPage.swift",
            "MacScreen/MacScreenPageService.swift", "Phone/PhonePage.swift", "Feed/FeedPageService.swift",
        ]
        for file in files {
            let source = try String(contentsOf: Self.appSources.appending(path: file), encoding: .utf8)
            #expect(source.components(separatedBy: declaration).count - 1 == 1, "\(file) declares one discard policy")
        }
        let coderouter = try String(contentsOf: Self.appSources.appending(path: "Apps/CodeRouterPageTab.swift"), encoding: .utf8)
        #expect(coderouter.contains("hiddenPolicy: hiddenPolicy"), "CodeRouter chooses its page's policy")
        #expect(CodeRouterPageTab.hiddenPolicy == .standard)
    }

    @Test func streamsGoWhenTheyStop() {
        #expect(PhonePageTab.hiddenPolicy == .afterHidden(.zero), "a hidden phone tab draws no frames")
        #expect(MacScreenPageService.hiddenPolicy == .afterHidden(MacScreenPane.defaultHiddenGrace),
                "a hidden Mac screen keeps its session for the pane's grace, then ends it")
        #expect(MacScreenPageService.hiddenPolicy.timeout == 20)
    }

    // MARK: Mobile Pairing

    @Test func mobilePairingKeepsItsPageWhileItsCodeWorks() {
        let now = Date(timeIntervalSince1970: 10_000)
        #expect(MobilePairingPageService.keepReasons(codeExpiresAt: nil, now: now).isEmpty, "no code shown, nothing to scan")
        #expect(MobilePairingPageService.keepReasons(codeExpiresAt: now.addingTimeInterval(300), now: now) == [.inProgress])
        #expect(MobilePairingPageService.keepReasons(codeExpiresAt: now, now: now).isEmpty, "an expired code pairs nothing")
    }

    // MARK: Cloud

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
        #expect(pages.pendingScopes[Self.deviceID] == .view)

        let second = pages.makeView(for: key)
        #expect(second !== first)
        #expect(pages.tab(key)?.pane?.model.hub?.resumeScope == .view, "showing the tab again asks for the scope it streamed")
        pages.tabClosed(key)
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
        let tab = PhonePageTab(phones: Self.phones())
        let key = "phone-batch5"
        tab.restore("sim:AAAA", for: key)
        let first = tab.makeView(for: key, in: nil)
        #expect(tab.keepReasons(for: key).isEmpty)
        let view = try #require(first as? PhoneTabView)
        view.notesField.stringValue = "the cart is empty"
        #expect(tab.keepReasons(for: key) == [.unsavedEdits], "notes typed for a recording live only in the view")
        view.notesField.stringValue = ""

        tab.nextDevice = PhoneDeviceID("sim:BBBB")
        tab.viewDiscarded(key)
        #expect(tab.route(for: key) == "sim:AAAA", "the tab forgot its phone")
        #expect(tab.keepReasons(for: key).isEmpty)
        let second = try #require(tab.makeView(for: key, in: nil) as? PhoneTabView)
        #expect(second !== view)
        #expect(second.route == "sim:AAAA")
        #expect(tab.nextDevice == PhoneDeviceID("sim:BBBB"), "a rebuilt tab took the phone the next new tab shows")
        tab.tabClosed(key)
    }

    // MARK: Inbox

    @Test func theInboxKeepsItsViewWhileABasketReplyIsTypedOrSent() throws {
        let model = FeedModel(source: MockFeedSource())
        model.replaceReports([FeedReport(id: "r1", sender: "host/alpha", body: "a report", createdAt: Date(timeIntervalSince1970: 1_000))])
        let host = FeedHostView(model: model)
        #expect(!host.hasTypedReply && !host.isSendingReply)
        let basket = ReportsBasketView(model: model, onReply: { _ in true })
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

    static let appSources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources/CmuxNextApp")

    static let deviceID = "0b6c1a2e-3d4f-4a5b-8c9d-aabbccddeeff"
    static let page = PageCallContext(page: PageDescriptor.cloud.id)
    static let confirmed = PageCallContext(page: PageDescriptor.cloud.id, origin: "user", confirmed: true)

    static func macScreenPages() -> MacScreenPages {
        let file = FileManager.default.temporaryDirectory.appending(path: "mac-screen-\(UUID().uuidString)/mac-screen.json")
        return MacScreenPages(store: MacScreenStore(file: file))
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
