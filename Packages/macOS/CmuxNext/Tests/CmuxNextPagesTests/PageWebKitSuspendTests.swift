import AppKit
import CmuxNextDesign
import CmuxNextHibernation
@testable import CmuxNextPages
import CmuxNextWakeups
import Foundation
import ObjectiveC
import Testing
import WebKit

// The WebKit suspend spike lives in this test target only: the gated
// `_suspendPage:` / `_resumePage:` SPI, the rule that picks how a hidden, frozen WebKit page is
// parked, and the bench that measures each mode. Hidden in the window stays the
// shipped park. Suspend or detach moves into CmuxNextPages Sources only in the change that wires it
// into `freezePage`, after the bench's macOS 26 and 27 numbers in perf-lead.md show a gain, and
// together with a guard that resumes the page (or refuses the call) on every evaluate and load path:
// WebKit raises on `evaluateJavaScript` to a suspended view, and `PageWebView` pushes script into
// hidden pages.

/// WebKit's `_suspendPage:`, `_resumePage:` and `_isSuspended` (`WKWebViewPrivate.h`), each called
/// only through the IMP `class_getInstanceMethod` found, so a WebKit without one never gets an
/// unknown selector.
struct PageSuspendSPI {
    typealias Reply = @convention(block) (ObjCBool) -> Void
    typealias Send = @convention(c) (AnyObject, Selector, Reply) -> Void
    typealias Read = @convention(c) (AnyObject, Selector) -> ObjCBool

    private let suspendMethod: (selector: Selector, call: Send)
    private let resumeMethod: (selector: Selector, call: Send)
    private let readMethod: (selector: Selector, call: Read)

    /// Nil when `type` lacks any of the three methods.
    init?(in type: AnyClass, suspend: String = "_suspendPage:", resume: String = "_resumePage:",
          isSuspended: String = "_isSuspended") {
        func method(_ name: String) -> (Selector, IMP)? {
            // crash-allow: WebKit private selector, called only through the IMP class_getInstanceMethod found (no unknown-selector exception).
            let selector = NSSelectorFromString(name)
            return class_getInstanceMethod(type, selector).map { (selector, method_getImplementation($0)) }
        }
        guard let suspendMethod = method(suspend), let resumeMethod = method(resume),
              let readMethod = method(isSuspended) else { return nil }
        self.suspendMethod = (suspendMethod.0, unsafeBitCast(suspendMethod.1, to: Send.self))
        self.resumeMethod = (resumeMethod.0, unsafeBitCast(resumeMethod.1, to: Send.self))
        self.readMethod = (readMethod.0, unsafeBitCast(readMethod.1, to: Read.self))
    }

    /// WebKit's own flag (`WebPageProxy::m_isSuspended`).
    @MainActor func isSuspended(_ view: AnyObject) -> Bool {
        readMethod.call(view, readMethod.selector).boolValue
    }

    /// Suspends `view` (`WebPageProxy::suspend`, the suspension a back-forward page gets): it runs no
    /// script, timer or animation and keeps its document. `done` gets the web process's answer.
    ///
    /// - Returns: WebKit's flag after the call; false with no call when `view` is already suspended.
    @MainActor @discardableResult
    func suspend(_ view: AnyObject, _ done: @escaping @MainActor (Bool) -> Void = { _ in }) -> Bool {
        guard !isSuspended(view) else { return false }
        send(suspendMethod, to: view, done)
        return isSuspended(view)
    }

    /// Resumes `view`. WebKit clears its flag in the call when it accepts; it refuses (and keeps the
    /// flag) for example when the page has no running process, so the answer is read back.
    ///
    /// - Returns: Whether the page runs now: only then may the same turn call into it. False with no
    ///   call when `view` is not suspended.
    @MainActor @discardableResult
    func resume(_ view: AnyObject, _ done: @escaping @MainActor (Bool) -> Void = { _ in }) -> Bool {
        guard isSuspended(view) else { return false }
        send(resumeMethod, to: view, done)
        return !isSuspended(view)
    }

    /// WebKit runs the reply on the main thread (its IPC replies arrive on the UI process's main run loop).
    @MainActor private func send(_ method: (selector: Selector, call: Send), to view: AnyObject,
                                 _ done: @escaping @MainActor (Bool) -> Void) {
        let reply: Reply = { ok in
            MainActor.assumeIsolated { done(ok.boolValue) } // main-proof: WebKit replies on the main run loop
        }
        method.call(view, method.selector, reply)
    }
}

extension PageWKWebView {
    /// This WebKit's suspend SPI, found once per process; nil when it lacks a part of it.
    static let pageSuspendSPI = PageSuspendSPI(in: WKWebView.self)

    var isPageSuspended: Bool { Self.pageSuspendSPI?.isSuspended(self) ?? false }

    @discardableResult
    func suspendPage(_ done: @escaping @MainActor (Bool) -> Void = { _ in }) -> Bool {
        Self.pageSuspendSPI?.suspend(self, done) ?? false
    }

    @discardableResult
    func resumePage(_ done: @escaping @MainActor (Bool) -> Void = { _ in }) -> Bool {
        Self.pageSuspendSPI?.resume(self, done) ?? false
    }
}

/// How a hidden, frozen WebKit page is parked (p13-webui.md 3.C, spike 029), chosen from
/// ``PageWebKitParkingBench``'s trials of each mode on the same page. Hidden in the window
/// is the default. Another mode wins only when, over every trial, it wakes less than
/// the current pick by more than ``wakeupMargin`` (its worst trial against the pick's best), its p95
/// show turn fits ``showTurnBudget`` and its p95 first frame after the show is at most
/// ``firstFrameAllowance`` later than hidden in the window's. Detached is considered only when hidden
/// in the window's median wakes more than ``detachWakeupFloor``. Chrome freezes a hidden page where
/// it is and never moves its view (`WebContents::SetPageFrozen`, content/public/browser/web_contents.h).
enum PageWebKitParking: String, CaseIterable, Sendable {
    case hiddenInWindow
    case suspended
    case detached

    /// One trial of one mode.
    struct Sample: Sendable, Equatable {
        /// Interrupt wakeups per second of the page's web process while parked.
        var wakeupsPerSecond: Double
        /// Main-thread time of the turn that shows the page again.
        var showTurn: Duration
        /// From the start of that turn to the page's first frame after it (one animation frame, then
        /// a task, as `PagePaintProbe`): what the person waits for, async resume and commit included.
        var firstFrame: Duration
    }

    /// Every trial of one mode.
    struct Measurement: Sendable, Equatable {
        var wakeupsPerSecond: [Double] = []
        var showTurns: [Duration] = []
        var firstFrames: [Duration] = []

        mutating func append(_ sample: Sample) {
            wakeupsPerSecond.append(sample.wakeupsPerSecond)
            showTurns.append(sample.showTurn)
            firstFrames.append(sample.firstFrame)
        }

        var isEmpty: Bool { wakeupsPerSecond.isEmpty || showTurns.isEmpty || firstFrames.isEmpty }
    }

    /// Hidden-in-window median wakeups per second at or under which a detach is never used.
    static let detachWakeupFloor = 0.2
    /// How much fewer wakeups per second a mode's worst trial must have than the pick's best trial.
    static let wakeupMargin = 0.05
    /// The most main-thread time (p95) the show's turn may take for a mode other than hidden in the window.
    static let showTurnBudget: Duration = .milliseconds(4)
    /// How much later (p95) than hidden in the window another mode's first frame after the show may
    /// come: one 60 Hz frame.
    static let firstFrameAllowance: Duration = .microseconds(16_667)

    /// The mode the trials pick. A nil or empty measurement is a mode not measured (no SPI, or not run).
    static func choose(hiddenInWindow: Measurement, suspended: Measurement?, detached: Measurement?) -> Self {
        guard !hiddenInWindow.isEmpty, let hiddenFrame = percentile(0.95, of: hiddenInWindow.firstFrames),
              let hiddenBest = hiddenInWindow.wakeupsPerSecond.min() else { return .hiddenInWindow }
        func fits(_ candidate: Measurement) -> Bool {
            guard !candidate.isEmpty, let turn = percentile(0.95, of: candidate.showTurns),
                  let frame = percentile(0.95, of: candidate.firstFrames) else { return false }
            return turn <= showTurnBudget && frame <= hiddenFrame + firstFrameAllowance
        }
        var pick = (mode: Self.hiddenInWindow, best: hiddenBest)
        func consider(_ mode: Self, _ candidate: Measurement) {
            guard fits(candidate), let worst = candidate.wakeupsPerSecond.max(),
                  let best = candidate.wakeupsPerSecond.min(), worst + wakeupMargin < pick.best else { return }
            pick = (mode, best)
        }
        if let suspended { consider(.suspended, suspended) }
        if let detached, let median = percentile(0.5, of: hiddenInWindow.wakeupsPerSecond), median > detachWakeupFloor {
            consider(.detached, detached)
        }
        return pick.mode
    }

    /// Nearest-rank percentile; nil for no values.
    static func percentile<Value: Comparable>(_ fraction: Double, of values: [Value]) -> Value? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }
}

@MainActor @Suite(.serialized)
struct PageWebKitSuspendTests {
    private typealias Measurement = PageWebKitParking.Measurement

    /// One trial per wakeup value, each with the same show turn and first frame.
    private static func measured(_ wakeups: [Double], turn: Int = 1, frame: Int = 20) -> Measurement {
        Measurement(wakeupsPerSecond: wakeups,
                    showTurns: Array(repeating: .milliseconds(turn), count: wakeups.count),
                    firstFrames: Array(repeating: .milliseconds(frame), count: wakeups.count))
    }

    // MARK: The parking rule

    @Test func hiddenInTheWindowStaysWhenNothingElseWasMeasured() {
        #expect(PageWebKitParking.choose(hiddenInWindow: Self.measured([11]), suspended: nil, detached: nil) == .hiddenInWindow)
        #expect(PageWebKitParking.choose(hiddenInWindow: Self.measured([11]), suspended: Measurement(), detached: Measurement()) == .hiddenInWindow,
                "no trials is not measured")
    }

    @Test func suspendWinsOnlyWhenItWakesLessWithinTheShowBudget() {
        let hidden = Self.measured([0.5, 0.5, 0.5])
        #expect(PageWebKitParking.choose(hiddenInWindow: hidden, suspended: Self.measured([0.1, 0.1, 0.1], turn: 2), detached: nil) == .suspended)
        #expect(PageWebKitParking.choose(hiddenInWindow: hidden, suspended: Self.measured([0.5, 0.5, 0.5]), detached: nil) == .hiddenInWindow,
                "an equal count is no gain")
        #expect(PageWebKitParking.choose(hiddenInWindow: hidden, suspended: Self.measured([0.1, 0.1, 0.1], turn: 5), detached: nil) == .hiddenInWindow,
                "a show turn over 4 ms")
    }

    @Test func aGainInsideTheRunToRunSpreadIsNoGain() {
        let hidden = Self.measured([0.4, 0.5, 0.6])
        #expect(PageWebKitParking.choose(hiddenInWindow: hidden, suspended: Self.measured([0.1, 0.2, 0.45]), detached: nil) == .hiddenInWindow,
                "suspend's worst trial overlaps hidden in the window's best")
        #expect(PageWebKitParking.choose(hiddenInWindow: Self.measured([0.5, 0.5]), suspended: Self.measured([0.47, 0.47]), detached: nil) == .hiddenInWindow,
                "under the margin")
        #expect(PageWebKitParking.choose(hiddenInWindow: hidden, suspended: Self.measured([0.1, 0.2, 0.3]), detached: nil) == .suspended)
    }

    @Test func oneSlowShowTurnOutOfFivePutsTheP95OverTheBudget() {
        var suspended = Self.measured([0.1, 0.1, 0.1, 0.1, 0.1])
        suspended.showTurns[3] = .milliseconds(9)
        #expect(PageWebKitParking.choose(hiddenInWindow: Self.measured([0.5, 0.5, 0.5, 0.5, 0.5]), suspended: suspended, detached: nil) == .hiddenInWindow)
    }

    @Test func aModeWhoseFirstFrameComesLaterThanOneFrameAfterHiddenInTheWindowLoses() {
        let hidden = Self.measured([0.5, 0.5], frame: 20)
        #expect(PageWebKitParking.choose(hiddenInWindow: hidden, suspended: Self.measured([0.1, 0.1], frame: 60), detached: nil) == .hiddenInWindow,
                "a fast show turn that paints a stale frame for 40 ms more")
        #expect(PageWebKitParking.choose(hiddenInWindow: hidden, suspended: Self.measured([0.1, 0.1], frame: 36), detached: nil) == .suspended)
    }

    @Test func detachIsNeverUsedWhileHiddenInTheWindowWakesAtMostTheFloor() {
        let detached = Self.measured([0, 0, 0])
        #expect(PageWebKitParking.choose(hiddenInWindow: Self.measured([0.2, 0.2, 0.2]), suspended: nil, detached: detached) == .hiddenInWindow)
        #expect(PageWebKitParking.choose(hiddenInWindow: Self.measured([0.1, 0.15, 0.9]), suspended: nil, detached: detached) == .hiddenInWindow,
                "the median, not one waking trial")
    }

    @Test func detachWinsOverAWakingHiddenPageOnlyWithinTheShowBudget() {
        let hidden = Self.measured([0.6, 0.6])
        #expect(PageWebKitParking.choose(hiddenInWindow: hidden, suspended: nil, detached: Self.measured([0.05, 0.05], turn: 4)) == .detached)
        #expect(PageWebKitParking.choose(hiddenInWindow: hidden, suspended: nil, detached: Self.measured([0.05, 0.05], turn: 9)) == .hiddenInWindow)
    }

    @Test func theModeThatWakesLeastWinsWhenBothFit() {
        let hidden = Self.measured([0.6, 0.6])
        #expect(PageWebKitParking.choose(hiddenInWindow: hidden, suspended: Self.measured([0.1, 0.1]), detached: Self.measured([0.3, 0.3])) == .suspended)
        #expect(PageWebKitParking.choose(hiddenInWindow: hidden, suspended: Self.measured([0.3, 0.3]), detached: Self.measured([0.1, 0.1])) == .detached)
    }

    @Test func thePercentileIsNearestRank() {
        #expect(PageWebKitParking.percentile(0.95, of: [Int]()) == nil)
        #expect(PageWebKitParking.percentile(0.95, of: [3, 1, 2, 5, 4]) == 5)
        #expect(PageWebKitParking.percentile(0.5, of: [3, 1, 2, 5, 4]) == 3)
        #expect(PageWebKitParking.percentile(0.95, of: Array(1...100)) == 95)
    }

    // MARK: The SPI gate

    @Test func aClassWithoutThePageSuspendSPIHasNone() {
        #expect(PageSuspendSPI(in: NSObject.self) == nil)
        #expect(PageSuspendSPI(in: FakeSuspendablePage.self, isSuspended: "_noSuchSelector") == nil, "one missing method is none")
    }

    @Test func theGateCallsTheMethodsItFoundAndHandsBackTheirAnswer() throws {
        let spi = try #require(PageSuspendSPI(in: FakeSuspendablePage.self))
        let page = FakeSuspendablePage()
        var answers: [Bool] = []
        #expect(!spi.isSuspended(page))
        #expect(spi.suspend(page) { answers.append($0) })
        #expect(spi.isSuspended(page))
        #expect(!spi.suspend(page), "a suspended page is not suspended again")
        #expect(spi.resume(page) { answers.append($0) })
        #expect(!spi.isSuspended(page))
        #expect(!spi.resume(page), "a running page is not resumed again")
        #expect(page.calls == ["suspend", "resume"])
        #expect(answers == [true, true])
    }

    /// WebKit refuses a resume (no running process) and keeps its flag: the caller must not call into
    /// the page in that turn, so the gate reports it still suspended.
    @Test func aRefusedResumeReportsThePageStillSuspended() throws {
        let spi = try #require(PageSuspendSPI(in: FakeSuspendablePage.self))
        let page = FakeSuspendablePage(refusesResume: true)
        var answer: Bool?
        #expect(spi.suspend(page))
        #expect(!spi.resume(page) { answer = $0 })
        #expect(spi.isSuspended(page))
        #expect(answer == false)
        #expect(page.calls == ["suspend", "resume"])
    }

    /// The selector check of the Tart macOS 14 and 15 runs and of the fleet's 26 and 27: a later
    /// change may only wire `.suspended` on a WebKit that has the SPI.
    @Test func thisWebKitHasThePageSuspendSPI() {
        #expect(PageWKWebView.pageSuspendSPI != nil)
    }

    // MARK: Live, one real page

    /// A hidden page suspends and resumes; WebKit's flag follows each call in the caller's turn, so
    /// the show's turn may call into the page right after an accepted resume.
    @Test(.timeLimit(.minutes(1)))
    func aHiddenPageSuspendsAndResumesInTheCallersTurn() async throws {
        try #require(PageWKWebView.pageSuspendSPI != nil)
        let window = PageParkingWindow()
        defer { window.close() }
        let view = try await window.loadedPage("<!doctype html><script>window.ticks = 0; setInterval(() => window.ticks++, 50)</script>")
        view.isHidden = true
        let suspended: Bool? = await PageTestWait.value("suspend reply") { (done: @escaping (Bool) -> Void) in
            #expect(view.suspendPage { done($0) })
            #expect(view.isPageSuspended)
            #expect(!view.suspendPage(), "a suspended page is not suspended again")
        }
        #expect(suspended == true)
        let resumed: Bool? = await PageTestWait.value("resume reply") { (done: @escaping (Bool) -> Void) in
            let running = view.resumePage { done($0) }
            #expect(running)
            #expect(!view.isPageSuspended)
            #expect(!view.resumePage(), "a running page is not resumed again")
            // WebKit raises on a call into a suspended view: this one, after an accepted resume, must not.
            if running { view.evaluateJavaScript("window.ticks", completionHandler: nil) }
        }
        #expect(resumed == true)
        view.isHidden = false
    }
}

/// The live numbers of spike 029, on a fleet GUI host (macOS 26 and 27):
/// `CMUX_PAGE_PARKING_BENCH=<seconds parked>` (30 by default), `CMUX_PAGE_PARKING_BENCH_TRIALS=<n>`
/// (5 by default). One page that keeps a 16 ms timer and a rAF loop is parked hidden in the window
/// (028), suspended and detached, in a fresh web process per trial, with the mode order rotated each
/// trial so drift spreads over every mode. Each trial waits until the page reports itself hidden, then
/// the lifecycle's freeze delay (`PageLifecyclePlanner.Timing.recentlyVisible`), so each mode is
/// measured from the state the lifecycle would freeze it in. Per trial: the web process's interrupt
/// wakeups per second over the parked span (`ri_interrupt_wkups`, the counter Chrome reports as idle
/// wakeups), the main-thread time of the show's turn, and the time from that turn to the page's first
/// frame after it. It prints p50/p95/max per mode and the mode
/// ``PageWebKitParking/choose(hiddenInWindow:suspended:detached:)`` picks; the numbers go to
/// perf-lead.md before any mode but hidden in the window is wired.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(60)),
       .enabled(if: ProcessInfo.processInfo.environment["CMUX_PAGE_PARKING_BENCH"] != nil))
struct PageWebKitParkingBench {
    static let wakingPage = """
    <!doctype html><title>parking</title><script>
    window.ticks = 0; setInterval(() => window.ticks++, 16);
    const frame = () => { window.ticks++; requestAnimationFrame(frame); }; requestAnimationFrame(frame);
    </script>
    """

    @Test func parkedWakeupsAndShowPerMode() async throws {
        let environment = ProcessInfo.processInfo.environment
        let seconds = max(Double(environment["CMUX_PAGE_PARKING_BENCH"] ?? "") ?? 30, 1)
        let trials = max(Int(environment["CMUX_PAGE_PARKING_BENCH_TRIALS"] ?? "") ?? 5, 1)
        let modes = PageWebKitParking.allCases.filter { $0 != .suspended || PageWKWebView.pageSuspendSPI != nil }
        var results: [PageWebKitParking: PageWebKitParking.Measurement] = [:]
        for trial in 0..<trials {
            for offset in modes.indices {
                let mode = modes[(trial + offset) % modes.count]
                let sample = try await Self.measure(mode, parkedFor: .seconds(seconds))
                results[mode, default: .init()].append(sample)
            }
        }
        for mode in modes {
            let measurement = try #require(results[mode])
            print("PAGE_PARKING_BENCH mode=\(mode.rawValue) seconds=\(seconds) trials=\(trials)"
                  + " wakeups_per_s=\(Self.spread(measurement.wakeupsPerSecond) { $0 })"
                  + " show_turn_ms=\(Self.spread(measurement.showTurns) { Self.milliseconds($0) })"
                  + " first_frame_ms=\(Self.spread(measurement.firstFrames) { Self.milliseconds($0) })")
        }
        let hidden = try #require(results[.hiddenInWindow])
        let choice = PageWebKitParking.choose(hiddenInWindow: hidden, suspended: results[.suspended], detached: results[.detached])
        print("PAGE_PARKING_BENCH choice=\(choice.rawValue) suspend_spi=\(PageWKWebView.pageSuspendSPI != nil)")
        #expect(results.count >= 2)
    }

    private static func measure(_ mode: PageWebKitParking, parkedFor span: Duration) async throws -> PageWebKitParking.Sample {
        let window = PageParkingWindow()
        defer { window.close() }
        let view = try await window.loadedPage(wakingPage)
        try await Self.nextFrame(of: view) // shown and painted
        let pid = try #require((view.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value)
        view.configuration.preferences.setHiddenPageThrottling(.full)
        let hidden = await window.waitForVisibility("hidden") {
            switch mode {
            case .hiddenInWindow, .suspended: view.isHidden = true
            case .detached: view.removeFromSuperview()
            }
        }
        try #require(hidden)
        try await Task.sleep(for: .seconds(PageLifecyclePlanner.Timing().recentlyVisible)) // the freeze delay
        if mode == .suspended { try #require(view.suspendPage()) }
        let start = try #require(ProcessUsage.interruptWakeups(of: pid))
        let clock = ContinuousClock()
        let began = clock.now
        try await Task.sleep(for: span)
        let end = try #require(ProcessUsage.interruptWakeups(of: pid))
        let parkedSeconds = Self.seconds(began.duration(to: clock.now))
        let showStart = clock.now
        switch mode {
        case .hiddenInWindow: view.isHidden = false
        case .suspended:
            try #require(view.resumePage())
            view.isHidden = false
        case .detached: window.content.addSubview(view)
        }
        window.window.displayIfNeeded()
        let showTurn = showStart.duration(to: clock.now)
        // A suspended page answers only after the web process handled the queued Resume; a reattached
        // one only after it committed a layer tree: this wait holds both.
        try await Self.nextFrame(of: view)
        let firstFrame = showStart.duration(to: clock.now)
        return .init(wakeupsPerSecond: Double(end &- start) / parkedSeconds, showTurn: showTurn, firstFrame: firstFrame)
    }

    /// One animation frame, then a task: the task runs after that frame rendered (`PagePaintProbe`).
    private static func nextFrame(of view: WKWebView) async throws {
        _ = try await view.callAsyncJavaScript(
            "await new Promise(r => requestAnimationFrame(() => setTimeout(r, 0))); return performance.now()",
            arguments: [:], in: nil, contentWorld: .page)
    }

    private static func spread<Value: Comparable>(_ values: [Value], _ number: (Value) -> Double) -> String {
        let p50 = PageWebKitParking.percentile(0.5, of: values).map(number) ?? .nan
        let p95 = PageWebKitParking.percentile(0.95, of: values).map(number) ?? .nan
        let low = values.min().map(number) ?? .nan
        let high = values.max().map(number) ?? .nan
        return "min:\(low),p50:\(p50),p95:\(p95),max:\(high)"
    }

    private static func milliseconds(_ duration: Duration) -> Double { seconds(duration) * 1_000 }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

/// A shown window with one fresh-process page in it, for the live tests and the bench. The page
/// reports `visibilitychange` to ``waitForVisibility(_:after:)``.
@MainActor
final class PageParkingWindow {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    var content: NSView { window.contentView ?? NSView() }
    private let waiter = PageParkingLoadWaiter()
    private let visibilityReports = PageParkingVisibility()

    init() {
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
    }

    /// A page with its own web process, loaded from `html`, in the window's content view.
    func loadedPage(_ html: String) async throws -> PageWKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.processPool = WKProcessPool()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(WKUserScript(
            source: "document.addEventListener('visibilitychange', () => window.webkit.messageHandlers.\(PageParkingVisibility.name).postMessage(document.visibilityState))",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController.add(visibilityReports, name: PageParkingVisibility.name)
        let view = PageWKWebView(frame: content.bounds, configuration: configuration)
        content.addSubview(view)
        view.navigationDelegate = waiter
        let loaded: Bool? = await PageTestWait.value("page load") { (done: @escaping (Bool) -> Void) in
            waiter.done = done
            view.loadHTMLString(html, baseURL: URL(string: "about:blank"))
        }
        view.navigationDelegate = nil
        try #require(loaded == true)
        return view
    }

    /// Runs `change`, then waits until the page reports `document.visibilityState == state`.
    func waitForVisibility(_ state: String, after change: () -> Void) async -> Bool {
        let reported: Bool? = await PageTestWait.value("visibilityState \(state)") { (done: @escaping (Bool) -> Void) in
            visibilityReports.waiting = (state, done)
            change()
        }
        return reported == true
    }

    func close() { window.close() }
}

@MainActor
private final class PageParkingVisibility: NSObject, WKScriptMessageHandler {
    static let name = "cmuxParkingVisibility"
    var waiting: (state: String, done: (Bool) -> Void)?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let waiting, message.body as? String == waiting.state else { return }
        self.waiting = nil
        waiting.done(true)
    }
}

@MainActor
private final class PageParkingLoadWaiter: NSObject, WKNavigationDelegate {
    var done: ((Bool) -> Void)?

    private func finish(_ ok: Bool) {
        done?(ok)
        done = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(true) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { finish(false) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { finish(false) }
}

/// Answers the three suspend methods as WebKit's view does: the flag changes in the call, the reply
/// comes after. A refused resume keeps the flag and answers false (`WebPageProxy::resume` without a
/// running process).
final class FakeSuspendablePage: NSObject {
    private(set) var calls: [String] = []
    private var suspended = false
    private let refusesResume: Bool

    init(refusesResume: Bool = false) {
        self.refusesResume = refusesResume
        super.init()
    }

    @objc(_suspendPage:) func suspendPage(_ reply: @escaping (Bool) -> Void) {
        calls.append("suspend")
        suspended = true
        reply(true)
    }

    @objc(_resumePage:) func resumePage(_ reply: @escaping (Bool) -> Void) {
        calls.append("resume")
        if !refusesResume { suspended = false }
        reply(!refusesResume)
    }

    @objc(_isSuspended) var isSuspended: Bool { suspended }
}
