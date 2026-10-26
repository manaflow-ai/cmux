import AppKit
@testable import CmuxNextPages
import CmuxNextWakeups
import Foundation
import ObjectiveC
import Testing
import WebKit

/// The WebKit suspend spike (p13-webui-029): the gated `_suspendPage:` / `_resumePage:` SPI and the
/// rule that picks how a hidden, frozen WebKit page is parked. The rule and the SPI gate run
/// everywhere; ``PageWebKitParkingBench`` takes the live numbers the rule reads.
@MainActor @Suite(.serialized)
struct PageWebKitSuspendTests {
    private typealias Measurement = PageWebKitParking.Measurement

    private static func measured(_ wakeups: Double, ms: Int) -> Measurement {
        Measurement(wakeupsPerSecond: wakeups, showTurn: .milliseconds(ms))
    }

    // MARK: The parking rule

    @Test func hiddenInTheWindowStaysWhenNothingElseWasMeasured() {
        #expect(PageWebKitParking.choose(hiddenInWindow: Self.measured(11, ms: 1), suspended: nil, detached: nil) == .hiddenInWindow)
    }

    @Test func suspendWinsOnlyWhenItWakesLessWithinTheShowBudget() {
        let hidden = Self.measured(0.5, ms: 1)
        #expect(PageWebKitParking.choose(hiddenInWindow: hidden, suspended: Self.measured(0.1, ms: 2), detached: nil) == .suspended)
        #expect(PageWebKitParking.choose(hiddenInWindow: hidden, suspended: Self.measured(0.5, ms: 1), detached: nil) == .hiddenInWindow,
                "an equal count is no gain")
        #expect(PageWebKitParking.choose(hiddenInWindow: hidden, suspended: Self.measured(0.1, ms: 5), detached: nil) == .hiddenInWindow,
                "a show turn over 4 ms")
    }

    @Test func detachIsNeverUsedWhileHiddenInTheWindowWakesAtMostTheFloor() {
        let detached = Self.measured(0, ms: 1)
        #expect(PageWebKitParking.choose(hiddenInWindow: Self.measured(0.2, ms: 1), suspended: nil, detached: detached) == .hiddenInWindow)
        #expect(PageWebKitParking.choose(hiddenInWindow: Self.measured(0.1, ms: 1), suspended: nil, detached: detached) == .hiddenInWindow)
    }

    @Test func detachWinsOverAWakingHiddenPageOnlyWithinTheShowBudget() {
        let hidden = Self.measured(0.6, ms: 1)
        #expect(PageWebKitParking.choose(hiddenInWindow: hidden, suspended: nil, detached: Self.measured(0.05, ms: 4)) == .detached)
        #expect(PageWebKitParking.choose(hiddenInWindow: hidden, suspended: nil, detached: Self.measured(0.05, ms: 9)) == .hiddenInWindow)
    }

    @Test func theModeThatWakesLeastWinsWhenBothFit() {
        let hidden = Self.measured(0.6, ms: 1)
        #expect(PageWebKitParking.choose(hiddenInWindow: hidden, suspended: Self.measured(0.1, ms: 1), detached: Self.measured(0.3, ms: 1)) == .suspended)
        #expect(PageWebKitParking.choose(hiddenInWindow: hidden, suspended: Self.measured(0.3, ms: 1), detached: Self.measured(0.1, ms: 1)) == .detached)
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
        spi.send(spi.suspend, to: page) { answers.append($0) }
        #expect(spi.isSuspended(page))
        spi.send(spi.resume, to: page) { answers.append($0) }
        #expect(!spi.isSuspended(page))
        #expect(page.calls == ["suspend", "resume"])
        #expect(answers == [true, true])
    }

    /// The selector check of the Tart macOS 14 and 15 runs and of the fleet's 26 and 27: the page
    /// lifecycle may only pick `.suspended` on a WebKit that has the SPI.
    @Test func thisWebKitHasThePageSuspendSPI() {
        #expect(PageWKWebView.pageSuspendSPI != nil)
    }

    // MARK: Live, one real page

    /// A hidden page suspends and resumes; WebKit's flag follows each call in the caller's turn, so
    /// the show's turn may call into the page right after the resume.
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
            #expect(view.resumePage { done($0) })
            #expect(!view.isPageSuspended)
            #expect(!view.resumePage(), "a running page is not resumed again")
            // WebKit raises on a call into a suspended view: this one, in the resume's turn, must not.
            view.evaluateJavaScript("window.ticks", completionHandler: nil)
        }
        #expect(resumed == true)
        view.isHidden = false
    }
}

/// The live numbers of spike 029 (`CMUX_PAGE_PARKING_BENCH=<seconds parked>`, 30 by default), on a
/// fleet GUI host (macOS 26 and 27): one page that keeps a 16 ms timer and a rAF loop, parked
/// hidden in the window (028), suspended and detached in turn, each in a fresh web process. Per mode:
/// the web process's interrupt wakeups per second over the parked span (`ri_interrupt_wkups`, the
/// counter Chrome reports as idle wakeups) and the main-thread time of the show's turn (unhide,
/// resume or reattach, then the window's layout and display in the same turn). It prints one
/// `PAGE_PARKING_BENCH` line per mode and the mode ``PageWebKitParking/choose(hiddenInWindow:suspended:detached:)``
/// picks; the numbers go to perf-lead.md before any mode but hidden in the window is wired.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(10)),
       .enabled(if: ProcessInfo.processInfo.environment["CMUX_PAGE_PARKING_BENCH"] != nil))
struct PageWebKitParkingBench {
    static let wakingPage = """
    <!doctype html><title>parking</title><script>
    window.ticks = 0; setInterval(() => window.ticks++, 16);
    const frame = () => { window.ticks++; requestAnimationFrame(frame); }; requestAnimationFrame(frame);
    </script>
    """

    @Test func parkedWakeupsAndShowTurnPerMode() async throws {
        let seconds = Double(ProcessInfo.processInfo.environment["CMUX_PAGE_PARKING_BENCH"] ?? "") ?? 30
        var results: [PageWebKitParking: PageWebKitParking.Measurement] = [:]
        for mode in PageWebKitParking.allCases where mode != .suspended || PageWKWebView.pageSuspendSPI != nil {
            let measurement = try await Self.measure(mode, parkedFor: .seconds(max(seconds, 1)))
            results[mode] = measurement
            print("PAGE_PARKING_BENCH mode=\(mode.rawValue) seconds=\(seconds) wakeups_per_s=\(measurement.wakeupsPerSecond) show_turn_ms=\(Self.seconds(measurement.showTurn) * 1_000)")
        }
        let hidden = try #require(results[.hiddenInWindow])
        let choice = PageWebKitParking.choose(hiddenInWindow: hidden, suspended: results[.suspended], detached: results[.detached])
        print("PAGE_PARKING_BENCH choice=\(choice.rawValue) suspend_spi=\(PageWKWebView.pageSuspendSPI != nil)")
        #expect(results.count >= 2)
    }

    private static func measure(_ mode: PageWebKitParking, parkedFor span: Duration) async throws -> PageWebKitParking.Measurement {
        let window = PageParkingWindow()
        defer { window.close() }
        let view = try await window.loadedPage(wakingPage)
        try await Task.sleep(for: .seconds(2)) // the document settles while shown
        let pid = try #require((view.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value)
        view.configuration.preferences.enableHiddenPageThrottling()
        switch mode {
        case .hiddenInWindow: view.isHidden = true
        case .suspended:
            view.isHidden = true
            #expect(view.suspendPage())
        case .detached: view.removeFromSuperview()
        }
        try await Task.sleep(for: .seconds(1)) // WebKit applies the hidden state on its own run loop turns
        let start = try #require(ProcessUsage.interruptWakeups(of: pid))
        let clock = ContinuousClock()
        let began = clock.now
        try await Task.sleep(for: span)
        let end = try #require(ProcessUsage.interruptWakeups(of: pid))
        let parkedSeconds = Self.seconds(began.duration(to: clock.now))
        let showStart = clock.now
        do {
            switch mode {
            case .hiddenInWindow: view.isHidden = false
            case .suspended:
                view.resumePage()
                view.isHidden = false
            case .detached: window.content.addSubview(view)
            }
            window.window.displayIfNeeded()
        }
        let showTurn = showStart.duration(to: clock.now)
        return .init(wakeupsPerSecond: Double(end &- start) / parkedSeconds, showTurn: showTurn)
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

/// A shown window with one fresh-process page in it, for the live tests and the bench.
@MainActor
final class PageParkingWindow {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    var content: NSView { window.contentView ?? NSView() }
    private let waiter = PageParkingLoadWaiter()

    init() {
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
    }

    /// A page with its own web process, loaded from `html`, in the window's content view.
    func loadedPage(_ html: String) async throws -> PageWKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.processPool = WKProcessPool()
        configuration.websiteDataStore = .nonPersistent()
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

    func close() { window.close() }
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
/// comes after.
final class FakeSuspendablePage: NSObject {
    private(set) var calls: [String] = []
    private var suspended = false

    @objc(_suspendPage:) func suspendPage(_ reply: @escaping (Bool) -> Void) {
        calls.append("suspend")
        suspended = true
        reply(true)
    }

    @objc(_resumePage:) func resumePage(_ reply: @escaping (Bool) -> Void) {
        calls.append("resume")
        suspended = false
        reply(true)
    }

    @objc(_isSuspended) var isSuspended: Bool { suspended }
}
