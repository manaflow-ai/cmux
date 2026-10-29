import AppKit
import CmuxNextDesign
import CmuxNextHibernation
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// Native pushes to a frozen page (MQ12): a frozen page gets no script, the thaw runs
/// the latest held push of each kind once, before anything sent after it, and a push that thaws first
/// (a command, a call that waits for the page's answer) thaws the page in the caller's turn, through
/// the page lifecycle, which freezes it again one recently visible window later. Every step is a call
/// in the test's turn; the lifecycle's clock moves only when the test moves it.
@MainActor @Suite(.serialized)
struct PageFrozenEvaluateTests {
    private let root: URL
    private let descriptor = PageDescriptor(id: "test.page-frozen-evaluate", resource: "page-frozen-evaluate", processGroup: .viewer, namespaces: [])
    private let window: NSWindow
    /// The tab's content view: hiding it hides the page, as a pane hides a tab.
    private let tab: NSView

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("page-frozen-evaluate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        tab = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView?.addSubview(tab)
    }

    private func finish(_ view: PageWebView) {
        view.close()
        window.close()
        try? FileManager.default.removeItem(at: root)
    }

    /// A loaded WebKit page in the tab whose scripts go to `bridge`.
    private func webKitView(_ bridge: RecordingBridge) throws -> PageWebView {
        let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], chromium: nil, deadlines: .testing()))
        view.frame = tab.bounds
        tab.addSubview(view)
        view.loaded = true
        view.scriptTarget.bridge = bridge
        return view
    }

    /// The same page, hidden, then frozen.
    private func frozenWebKitView(_ bridge: RecordingBridge) throws -> PageWebView {
        let view = try webKitView(bridge)
        tab.isHidden = true
        #expect(view.freezePage())
        bridge.scripts.removeAll()
        return view
    }

    // MARK: Held

    /// A minute of once-a-second pushes of every held kind reaches a frozen page as no script; the
    /// thaw runs one per kind, the newest, in the order those were sent.
    @Test func aFrozenPageGetsNoScriptAndItsThawRunsTheNewestOfEachKindOnce() throws {
        let bridge = RecordingBridge()
        let view = try frozenWebKitView(bridge)
        defer { finish(view) }
        for second in 0..<60 {
            view.pushes.run("theme(\(second))", whileFrozen: .latest(.theme))
            view.pushes.run("scale(\(second))", whileFrozen: .latest(.interfaceScale))
            view.open(route: "#s\(second)")
        }
        #expect(bridge.scripts.isEmpty, "a frozen page ran \(bridge.scripts.count) scripts")
        #expect(view.pushes.heldScripts.count == 3)

        tab.isHidden = false
        #expect(view.frozenEngine == nil)
        #expect(bridge.scripts == ["theme(59)", "scale(59)", "window.location.hash = \"#s59\";"])
        view.evaluate("after()")
        #expect(bridge.scripts.last == "after()")
        #expect(bridge.scripts.count == 4, "the thaw ran the held pushes again")
    }

    /// The real theme path: every change while frozen is held, and the show runs the theme once.
    @Test func theThemeOfAFrozenPageIsPushedOnceOnItsThaw() throws {
        let bridge = RecordingBridge()
        let view = try frozenWebKitView(bridge)
        defer { finish(view) }
        for _ in 0..<5 { view.applyTheme(force: true) }
        view.setDocumentAttribute("app-sidebar", "hidden")
        view.setDocumentAttribute("app-sidebar", "shown")
        #expect(bridge.scripts.isEmpty)

        tab.isHidden = false
        let theme = view.currentTheme().applyScript
        #expect(bridge.scripts.filter { $0 == theme }.count == 1, "the thaw pushed the theme \(bridge.scripts.filter { $0 == theme }.count) times")
        #expect(bridge.scripts.filter { $0.contains("app-sidebar") }.count == 1)
    }

    /// The newest push of a kind moves last: a later push never runs before an older one it replaced.
    @Test func aNewerPushOfAKindRunsAfterThePushesSentBeforeIt() throws {
        let bridge = RecordingBridge()
        let view = try frozenWebKitView(bridge)
        defer { finish(view) }
        view.pushes.run("theme(1)", whileFrozen: .latest(.theme))
        view.pushes.run("route(1)", whileFrozen: .latest(.route))
        view.pushes.run("theme(2)", whileFrozen: .latest(.theme))
        view.thawPage()
        #expect(bridge.scripts == ["route(1)", "theme(2)"])
        view.thawPage()
        #expect(bridge.scripts.count == 2, "a second thaw ran the held pushes again")
    }

    /// A glass feed push (wallpaper, art, blur) to a frozen page is held as the latest of its kind: it
    /// runs no script and never thaws the page; the thaw runs the newest one once.
    @Test func aGlassPushToAFrozenPageIsHeldAndItsThawRunsItOnce() throws {
        let bridge = RecordingBridge()
        let view = try frozenWebKitView(bridge)
        defer { finish(view) }
        view.pushGlass("glass(1)")
        view.pushGlass("glass(2)")
        #expect(bridge.scripts.isEmpty, "a frozen page ran \(bridge.scripts.count) glass scripts")
        #expect(view.frozenEngine != nil, "a glass push thawed the frozen page")
        #expect(view.pushes.heldScripts == ["glass(2)"])

        view.thawPage()
        #expect(bridge.scripts == ["glass(2)"])
        view.pushGlass("glass(3)")
        #expect(bridge.scripts == ["glass(2)", "glass(3)"], "a running page's glass push was held")
    }

    /// A freeze starts with nothing held: what was held for a document that ended while frozen (a
    /// discard, a Chromium page that ended) never reaches the next one.
    @Test func aFreezeStartsWithNothingHeld() throws {
        let bridge = RecordingBridge()
        let view = try frozenWebKitView(bridge)
        defer { finish(view) }
        view.pushes.run("theme(old)", whileFrozen: .latest(.theme))
        view.frozenEngine = nil // the document ended without a thaw
        #expect(view.freezePage())
        #expect(view.pushes.heldScripts.isEmpty)
        view.thawPage()
        #expect(bridge.scripts.isEmpty)
    }

    // MARK: Thaws first

    /// A command to a frozen page thaws it in the caller's turn; the held pushes run first.
    @Test func aCommandThawsTheFrozenPageFirstAndRunsAfterTheHeldPushes() throws {
        let bridge = RecordingBridge()
        let view = try frozenWebKitView(bridge)
        defer { finish(view) }
        view.pushes.run("theme(1)", whileFrozen: .latest(.theme))
        view.evaluate("command()")
        #expect(view.frozenEngine == nil)
        #expect(!view.webView.isHidden, "WebKit's view was not thawed")
        #expect(!view.isShownInWindow, "the thaw for a call showed the page")
        #expect(bridge.scripts == ["theme(1)", "command()"])
    }

    /// Chromium: the page thaws (`setFrozen(false)`) before the held pushes run, and it stays hidden.
    @Test func aChromiumPageThawsBeforeItsHeldPushesRun() async throws {
        let hosting = FakeChromiumHosting()
        let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], chromium: hosting, deadlines: .testing()))
        defer { finish(view) }
        view.chromiumDeadlines = LifecycleDeadlineRig.never
        await view.chromiumStart?.value
        view.frame = tab.bounds
        tab.addSubview(view)
        let page = try #require(hosting.made.first)
        view.loaded = true
        let bridge = RecordingBridge()
        view.scriptTarget.bridge = bridge
        tab.isHidden = true
        #expect(view.freezePage())
        var stepsAtFirstScript: [FakeChromiumPage.LifecycleStep]?
        bridge.onEvaluate = { if stepsAtFirstScript == nil { stepsAtFirstScript = page.lifecycleSteps } }

        view.pushes.run("theme(1)", whileFrozen: .latest(.theme))
        view.pushes.run("theme(2)", whileFrozen: .latest(.theme))
        #expect(bridge.scripts.isEmpty)
        let before = page.lifecycleSteps.count
        view.evaluate("command()")
        #expect(bridge.scripts == ["theme(2)", "command()"])
        #expect(stepsAtFirstScript?.last == .frozen(false), "a held push ran before the thaw")
        #expect(Array(page.lifecycleSteps.dropFirst(before)) == [.frozen(false)], "the thaw for a call showed the page")
    }

    /// The lifecycle froze the page: a call thaws it through the lifecycle, which counts it hidden and
    /// freezes it again at its next pass, at the latest one recently visible window later.
    @Test func aCallThawsThroughTheLifecycleWhichFreezesThePageAgainLater() throws {
        let rig = LifecycleDeadlineRig()
        let lifecycle = PageLifecycle(deadlines: rig.scheduler)
        let bridge = RecordingBridge()
        let view = try webKitView(bridge)
        defer { finish(view) }
        let encoder = PageSnapshotEncoder { _, done in done(nil) }
        lifecycle.hide("a", page: PageWebViewLifecycle(view, encoder: encoder))
        tab.isHidden = true
        rig.advance(to: .seconds(5))
        let other = OtherPage()
        lifecycle.hide("b", page: other) // takes mostRecentlyUsed, so "a" may freeze at 10 s
        rig.fire()
        #expect(lifecycle.state(of: "a") == .frozen)
        #expect(view.frozenEngine != nil)

        view.evaluate("command()")
        #expect(view.frozenEngine == nil)
        #expect(lifecycle.state(of: "a") == .hidden)
        #expect(bridge.scripts.last == "command()")
        let window = Duration.seconds(PageLifecyclePlanner().timing.visibleWindow(energySaver: false))
        let next = try #require(lifecycle.nextPassAt, "no pass to freeze the page again")
        #expect(next <= rig.now + window)

        rig.fire()
        #expect(lifecycle.state(of: "a") == .frozen, "the page was not frozen again")
        #expect(view.frozenEngine != nil)
    }

    /// A call that waits for a frozen Chromium page's answer thaws it, and no pass freezes it again
    /// before the answer: not one armed before the thaw, nor one after the thaw's window. Once the
    /// answer came, the next pass freezes it.
    @Test func aPageWaitingForACallsAnswerIsNotFrozenUntilTheAnswerComes() async throws {
        let hosting = FakeChromiumHosting()
        let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], chromium: hosting, deadlines: .testing()))
        defer { finish(view) }
        view.chromiumDeadlines = LifecycleDeadlineRig.never
        await view.chromiumStart?.value
        view.frame = tab.bounds
        tab.addSubview(view)
        let page = try #require(hosting.made.first)
        view.loaded = true

        let rig = LifecycleDeadlineRig()
        let lifecycle = PageLifecycle(deadlines: rig.scheduler)
        let encoder = PageSnapshotEncoder { _, done in done(nil) }
        lifecycle.hide("a", page: PageWebViewLifecycle(view, encoder: encoder))
        tab.isHidden = true
        rig.advance(to: .seconds(5))
        lifecycle.hide("b", page: OtherPage()) // takes mostRecentlyUsed, so "a" may freeze at 10 s
        rig.fire()
        #expect(lifecycle.state(of: "a") == .frozen)
        #expect(page.lifecycleSteps.last == .frozen(true))

        let answer = HeldAnswer()
        page.evaluateGate = { await answer.gate() }
        let call = Task { _ = await view.callPageFunction("return 1;") }
        await answer.waitUntilEntered()
        #expect(lifecycle.state(of: "a") == .hidden)
        #expect(page.lifecycleSteps.last == .frozen(false), "the call did not thaw the page first")
        let thawed = page.lifecycleSteps.count

        // A pass armed before the thaw's window ends: "b"'s hide moves mostRecentlyUsed off "b" at 15 s.
        lifecycle.hide("c", page: OtherPage())
        let window = Duration.seconds(PageLifecyclePlanner().timing.visibleWindow(energySaver: false))
        let early = try #require(lifecycle.nextPassAt)
        #expect(early < rig.now + window, "no pass armed inside the thaw's window")
        rig.fire()
        #expect(rig.now == early)
        #expect(lifecycle.state(of: "a") == .hidden, "a pass froze the page under its call")
        // The thaw's window ended; the call still waits.
        rig.fire()
        #expect(rig.now >= early + .seconds(5))
        #expect(lifecycle.state(of: "a") == .hidden, "a pass froze the page under its call")
        #expect(!page.lifecycleSteps.dropFirst(thawed).contains(.frozen(true)), "the page froze before its answer")

        answer.answer()
        await call.value
        rig.fire()
        #expect(lifecycle.state(of: "a") == .frozen, "the page did not freeze once its answer came")
        #expect(page.lifecycleSteps.last == .frozen(true))
    }
}

/// An answer a test holds back: ``gate()`` waits until ``answer()``.
@MainActor
private final class HeldAnswer {
    private var entered = false
    private var onEnter: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?

    func gate() async {
        entered = true
        onEnter?.resume()
        onEnter = nil
        await withCheckedContinuation { release = $0 }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { onEnter = $0 }
    }

    func answer() {
        release?.resume()
        release = nil
    }
}

/// A bridge that records each script instead of running it.
@MainActor
private final class RecordingBridge: PageHostBridge {
    let engine = PageHostEngine.webKit
    var scripts: [String] = []
    /// Runs before each script is recorded.
    var onEvaluate: (() -> Void)?

    func install(_ handler: @escaping PageHostHandler) {}
    func evaluate(_ script: String) {
        onEvaluate?()
        scripts.append(script)
    }
    func uninstall() {}
}

/// A second hidden page with nothing to freeze: it only takes the most recently used role.
@MainActor
private final class OtherPage: PageLifecycleTarget {
    var object: AnyObject? { self }
    var lifecycleGroup: String? { "viewer" }
    var lifecycleKeepReasons: Set<PageLifecyclePlanner.KeepReason> { [] }
    func reportsReasonChanges(to lifecycle: PageLifecycle) {}
    func keepHideSnapshot() {}
    func dropHideSnapshot() {}
    func freeze() -> Bool { true }
    func thaw() {}
    func discard() -> Bool { true }
}
