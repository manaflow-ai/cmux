import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextInput
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextSettings
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// A cmux page in Chromium follows Chrome's launch order through the engine's one deferral path.
/// The fake engine waits as `CEFEngine.makeTab` does, on the real ``CEFLaunchDeferral`` over the
/// tab origin ``ChromiumPageHost`` sets (``BrowserTabOrigin/init(_:)``), and answers the page through a real
/// ``ChromiumPageHost`` over a Chromium slot whose engine is never built. A page the launch restored that shows starts in the
/// first afterFirstFrame slot (one wait in all); one that does not show starts after completion; a person's or a
/// script's open starts at once while the launch runs.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct ChromiumPageLaunchOriginTests {
    @Test func aRestoredPageInFrontStartsChromiumInTheFirstAfterFirstFrameSlot() async throws {
        let rig = try LaunchPageRig()
        defer { rig.close() }
        let ran = RunOrder()
        rig.launch.startup.post(.afterFirstFrame, "Test.before", on: .main) { ran.names.append("before") }
        let view = try rig.open(.launchRestore)
        #expect(view.awaitsFirstShow, "a restored page starts at its show, not when it is made")
        rig.window(.visible).contentView?.addSubview(view)
        #expect(!view.awaitsFirstShow)
        await rig.settle()
        #expect(rig.hosting.origins == [.restoreVisible], "the shown page asked the engine at once: the engine's wait is the only one")
        #expect(rig.hosting.made.isEmpty, "the engine started Chromium before the first frame")

        rig.launch.hand.drain()
        rig.launch.startup.firstFrameCommitted()
        rig.launch.startup.post(.afterFirstFrame, "Test.after", on: .main) { ran.names.append("after") }
        rig.launch.hand.drain()
        let slots = rig.launch.startup.log.records.filter { $0.priority == .afterFirstFrame }.map { "\($0.name)" }
        #expect(slots == ["Test.before", "Chromium.start.restoreVisible", "Test.after"],
                "one afterFirstFrame wait, released with the first frame, before work posted after it")

        rig.fireFrames()
        let start = try #require(view.chromiumStart)
        await start.value
        #expect(rig.hosting.made.count == 1)
        #expect(ran.names == ["before", "after"])
        #expect(rig.launch.startup.completion == nil, "the shown page must not wait for completion (its pane holds completion open)")
    }

    @Test func aHiddenRestoredPageAsksForNoChromiumBeforeCompletion() async throws {
        let rig = try LaunchPageRig()
        defer { rig.close() }
        let view = try rig.open(.launchRestore)
        rig.window(.hidden).contentView?.addSubview(view)
        await rig.settle()
        rig.launch.hand.drain()
        rig.launch.startup.finishRegistration()
        rig.launch.startup.firstFrameCommitted()
        rig.fireFrames()
        await rig.settle()
        #expect(view.awaitsFirstShow)
        #expect(view.chromiumStart == nil)
        #expect(rig.hosting.origins.isEmpty, "a hidden restored page asked for Chromium before startup completed")

        rig.launch.hand.drain() // the posted completion
        #expect(rig.launch.startup.completion != nil)
        #expect(view.awaitsFirstShow, "the hidden start waits for its afterStartup turn")
        rig.fireFrames()
        #expect(!view.awaitsFirstShow)
        let start = try #require(view.chromiumStart)
        await start.value
        #expect(rig.hosting.origins == [.user], "after completion no origin waits")
        #expect(rig.hosting.made.count == 1)
    }

    /// A restored page that waited hidden and shows before completion starts as the shown one, once.
    @Test func aHiddenRestoredPageThatShowsStartsAsRestoredVisible() async throws {
        let rig = try LaunchPageRig()
        defer { rig.close() }
        let view = try rig.open(.launchRestore)
        rig.window(.hidden).contentView?.addSubview(view)
        await rig.settle()
        rig.launch.hand.drain()
        rig.launch.startup.firstFrameCommitted()
        rig.window(.visible).contentView?.addSubview(view)
        await rig.settle()
        #expect(rig.hosting.origins == [.restoreVisible])
        rig.launch.hand.drain()
        rig.fireFrames()
        let start = try #require(view.chromiumStart)
        await start.value
        #expect(rig.hosting.made.count == 1)
        #expect(rig.launch.startup.completion == nil)

        rig.launch.complete()
        rig.fireFrames()
        await rig.settle()
        #expect(rig.hosting.made.count == 1, "its afterStartup turn started the page a second time")
    }

    /// A person's or a script's open during the launch is never a restored one: it starts at once, also hidden.
    @Test func aUserOrAutomationOpenDuringTheLaunchStartsChromiumAtOnce() async throws {
        let rig = try LaunchPageRig()
        defer { rig.close() }
        let user = try rig.open(.user), script = try rig.open(.automation)
        #expect(!user.awaitsFirstShow)
        #expect(!script.awaitsFirstShow)
        let starts = [try #require(user.chromiumStart), try #require(script.chromiumStart)]
        for start in starts { await start.value }
        #expect(rig.hosting.origins == [.user, .automation])
        #expect(rig.hosting.made.count == 2)
        #expect(rig.launch.hand.count == 0, "an open that is not a restore posted a launch turn")
        #expect(rig.launch.startup.completion == nil)
    }

    /// Feature `cefLaunchOrigin` off: the slot's launch order has no scheduler, so a restored page starts at once.
    @Test func withNoLaunchOrderARestoredPageStartsAtOnce() async throws {
        let rig = try LaunchPageRig(launchRuns: false)
        defer { rig.close() }
        let view = try rig.open(.launchRestore)
        #expect(!view.awaitsFirstShow)
        let start = try #require(view.chromiumStart)
        await start.value
        #expect(rig.hosting.origins == [.user])
    }

    @Test func aRestoredPageClosedBeforeCompletionNeverStarts() async throws {
        let rig = try LaunchPageRig()
        defer { rig.close() }
        let view = try rig.open(.launchRestore)
        rig.window(.hidden).contentView?.addSubview(view)
        await rig.settle()
        rig.webUI.close(view)
        rig.launch.complete()
        rig.fireFrames()
        await rig.settle()
        #expect(view.chromiumStart == nil)
        #expect(rig.hosting.origins.isEmpty)
    }

    /// The origin ChromiumPageHost gives the engine is the page's, case for case.
    @Test func thePageOriginMapsToTheSameTabOrigin() {
        #expect(PageChromiumOrigin.allCases.count == BrowserTabOrigin.allCases.count)
        for origin in PageChromiumOrigin.allCases {
            #expect(BrowserTabOrigin(origin).rawValue == "\(origin)")
            #expect(PageChromiumOrigin(BrowserTabOrigin(origin)) == origin)
        }
    }
}

/// The order in which test posts ran.
@MainActor private final class RunOrder {
    var names: [String] = []
}

/// A page host over a fake engine that waits on the real launch order, as `CEFEngine.makeTab` does.
@MainActor private final class LaunchPageRig {
    let launch: StartupTestScheduler
    let hosting: FakeChromiumHosting
    let webUI: WebUIHost
    /// The App's Chromium slot; its engine is never built here (the fake makes the pages).
    let slot: ChromiumEngineSlot
    private let root: URL
    private let descriptor = PageDescriptor(id: "test.launch-origin", resource: "launch-origin", processGroup: .solo, namespaces: [])
    private var windows: [NSWindow] = []
    private var views: [PageWebView] = []
    /// The scheduler ``settle()`` waits on: one background task of it is one main-actor turn.
    private let settleWork = MainWorkScheduler(budget: MainFrameBudget())

    /// - Parameter launchRuns: The slot's launch order is over the launch's scheduler (feature `cefLaunchOrigin` on).
    init(launchRuns: Bool = true) throws {
        let launch = StartupTestScheduler(), hosting = FakeChromiumHosting()
        let fixture = CEFEngine(layout: nil, stores: .inMemory(), signInCallbacks: CEFSignInCallbacks(), input: InputEventTap())
        let slot = ChromiumEngineSlot(stores: fixture.stores, waitDeadlines: fixture.waitDeadlines, source: CEFRuntimeSource(layout: nil),
                                      launch: launchRuns ? launch.startup : nil, make: { _, _, _ in fixture }, stop: { _ in })
        let host = ChromiumPageHost(chromium: slot, preference: { BrowserDefaultEngine.chromium }, keyRouter: nil, work: hosting.work,
                                    mainWork: MainWorkScheduler(budget: MainFrameBudget()), dialogs: hosting.dialogs, hangWork: nil)
        (self.launch, self.hosting, self.slot) = (launch, hosting, slot)
        hosting.launchOrder = FakeChromiumHosting.LaunchOrder(
            restoredOrigin: { host.restoredOrigin(isShown: $0) },
            startHidden: { host.startHidden(when: $0, $1) },
            // CEFEngine.makeTab's wait, over the tab origin ChromiumPageHost.makePage sets.
            waitForStart: { await slot.launchOrder.waitForStart(of: BrowserTabOrigin($0)) })
        webUI = WebUIHost(chromium: hosting, openPanel: nil, memory: QuietMemoryRegistry(), deadlines: .testing())
        root = FileManager.default.temporaryDirectory.appendingPathComponent("page-launch-origin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    /// A page view opened by `origin`, in no window yet.
    func open(_ origin: PageOpenOrigin) throws -> PageWebView {
        let view = try #require(webUI.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [], route: "#/home", origin: origin)))
        views.append(view)
        return view
    }

    /// A window ordered in whose visibility node reads `state` (AppKit reports the off-screen test window covered).
    func window(_ state: Visibility) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -4_000, y: -4_000, width: 900, height: 640),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        _ = WindowVisibilitySource.of(window, read: { _ in state })
        windows.append(window)
        return window
    }

    /// A few main-actor turns: a start that is not held reaches the engine in them.
    func settle() async {
        for _ in 0..<5 { await settleWork.apply(.background, owner: "ChromiumPageLaunchOriginTests.settle") { () -> Void in } }
    }

    /// A few display frames: the released afterFirstFrame and afterStartup tasks run in them.
    func fireFrames() {
        for _ in 0..<3 { launch.fire() }
    }

    func close() {
        #expect(slot.built == nil, "a page start built the real engine")
        views.forEach { webUI.close($0) }
        windows.forEach { $0.close() }
        try? FileManager.default.removeItem(at: root)
    }
}
