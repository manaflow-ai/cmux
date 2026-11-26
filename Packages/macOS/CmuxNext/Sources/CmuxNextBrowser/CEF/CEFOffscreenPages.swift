import AppKit
import CmuxNextCompat
import CmuxNextDesign
import IOSurface
import QuartzCore
import os

// Off-screen pages (approach 5 prototype, cmuxterm-hq artifacts/in-tree-pages/approaches/osr): CEF windowless
// rendering with shared textures. Chromium draws each frame of a page into an IOSurface (CefRenderHandler::
// OnAcceleratedPaint); the shim copies it into one of its own (shim_offscreen.mm) and this file shows it as a layer's
// contents in the pane, so cmux decides when and where a page's pixels appear. Input goes back through CefBrowserHost:
// mouse, wheel, keys, IME, edit commands and file drags, all turned into Chromium's events here by hand.
//
// A windowless browser is Alloy style: CEF refuses Chrome style with windowless rendering
// (browser_host_create.cc, CefBrowserCreateParams::MaybeSetWindowInfo), so an off-screen page has no Chrome window,
// no tab strip and none of the fork's Chrome-style calls (tabs, extensions UI, side panel, layer hosting).

private let offscreenLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "cef-offscreen")

/// The shim's off-screen calls (`cmux_cef_shim.h`, "Off-screen pages"); nil in a shim without them.
nonisolated struct CEFOffscreenShim: @unchecked Sendable {
    let enable: @convention(c) (Int32, Int32) -> Void
    let setHandlers: @convention(c) (UnsafeRawPointer?, UnsafeMutableRawPointer?) -> Void
    let create: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?,
                                UnsafePointer<CChar>?, Int32) -> Int32
    let isOffscreen: @convention(c) (Int32) -> Int32
    let wasResized: @convention(c) (Int32) -> Void
    let wasHidden: @convention(c) (Int32, Int32) -> Void
    let screenInfoChanged: @convention(c) (Int32) -> Void
    let invalidate: @convention(c) (Int32) -> Void
    let setFrameRate: @convention(c) (Int32, Int32) -> Void
    let beginFrame: @convention(c) (Int32) -> Void
    let mouse: @convention(c) (Int32, Int32, Int32, Int32, UInt32, Int32, Int32) -> Void
    let wheel: @convention(c) (Int32, Int32, Int32, UInt32, Int32, Int32) -> Void
    let key: @convention(c) (Int32, Int32, UInt32, Int32, UInt16, UInt16) -> Void
    let imeSetComposition: @convention(c) (Int32, UnsafePointer<CChar>?, Int32, Int32, Int32, Int32) -> Void
    let imeCommit: @convention(c) (Int32, UnsafePointer<CChar>?, Int32, Int32, Int32) -> Void
    let imeFinish: @convention(c) (Int32, Int32) -> Void
    let imeCancel: @convention(c) (Int32) -> Void
    let edit: @convention(c) (Int32, Int32) -> Void
    let drag: @convention(c) (Int32, Int32, Int32, Int32, UInt32, UnsafePointer<UnsafePointer<CChar>?>?, Int32,
                              Int32) -> Int32
    let counters: @convention(c) (UnsafeMutablePointer<UInt64>?, Int32) -> Void

    /// Every call by its symbol name; nil when one is missing.
    init?(lookup: (String) -> UnsafeMutableRawPointer?) {
        func fn<T>(_ name: String) -> T? { lookup("cmux_shim_osr_" + name).map { unsafeBitCast($0, to: T.self) } }
        guard let enable: @convention(c) (Int32, Int32) -> Void = fn("enable"),
              let setHandlers: @convention(c) (UnsafeRawPointer?, UnsafeMutableRawPointer?) -> Void = fn("set_handlers"),
              let create: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?,
                                          UnsafePointer<CChar>?, Int32) -> Int32 = fn("create"),
              let isOffscreen: @convention(c) (Int32) -> Int32 = fn("is_offscreen"),
              let wasResized: @convention(c) (Int32) -> Void = fn("was_resized"),
              let wasHidden: @convention(c) (Int32, Int32) -> Void = fn("was_hidden"),
              let screenInfoChanged: @convention(c) (Int32) -> Void = fn("screen_info_changed"),
              let invalidate: @convention(c) (Int32) -> Void = fn("invalidate"),
              let setFrameRate: @convention(c) (Int32, Int32) -> Void = fn("set_frame_rate"),
              let beginFrame: @convention(c) (Int32) -> Void = fn("begin_frame"),
              let mouse: @convention(c) (Int32, Int32, Int32, Int32, UInt32, Int32, Int32) -> Void = fn("mouse"),
              let wheel: @convention(c) (Int32, Int32, Int32, UInt32, Int32, Int32) -> Void = fn("wheel"),
              let key: @convention(c) (Int32, Int32, UInt32, Int32, UInt16, UInt16) -> Void = fn("key"),
              let imeSetComposition: @convention(c) (Int32, UnsafePointer<CChar>?, Int32, Int32, Int32, Int32) -> Void =
                fn("ime_set_composition"),
              let imeCommit: @convention(c) (Int32, UnsafePointer<CChar>?, Int32, Int32, Int32) -> Void = fn("ime_commit"),
              let imeFinish: @convention(c) (Int32, Int32) -> Void = fn("ime_finish"),
              let imeCancel: @convention(c) (Int32) -> Void = fn("ime_cancel"),
              let edit: @convention(c) (Int32, Int32) -> Void = fn("edit"),
              let drag: @convention(c) (Int32, Int32, Int32, Int32, UInt32, UnsafePointer<UnsafePointer<CChar>?>?, Int32,
                                        Int32) -> Int32 = fn("drag"),
              let counters: @convention(c) (UnsafeMutablePointer<UInt64>?, Int32) -> Void = fn("counters")
        else { return nil }
        self.enable = enable
        self.setHandlers = setHandlers
        self.create = create
        self.isOffscreen = isOffscreen
        self.wasResized = wasResized
        self.wasHidden = wasHidden
        self.screenInfoChanged = screenInfoChanged
        self.invalidate = invalidate
        self.setFrameRate = setFrameRate
        self.beginFrame = beginFrame
        self.mouse = mouse
        self.wheel = wheel
        self.key = key
        self.imeSetComposition = imeSetComposition
        self.imeCommit = imeCommit
        self.imeFinish = imeFinish
        self.imeCancel = imeCancel
        self.edit = edit
        self.drag = drag
        self.counters = counters
    }
}

/// One frame the shim hands over (`cmux_shim_osr_frame`), read at its C offsets.
nonisolated struct CEFOffscreenFrame {
    var isPopup: Bool
    var surface: IOSurfaceRef?
    var width: Int
    var height: Int
    var letterboxed: Bool

    init(_ raw: UnsafeRawPointer) {
        // int type @0, void* io_surface @8, int width @16, height @20, source_width @24, source_height @28,
        // int letterboxed @32, uint64 capture_counter @40, int64 timestamp_us @48 (arm64, natural alignment).
        isPopup = raw.load(fromByteOffset: 0, as: Int32.self) == 1
        let pointer = raw.load(fromByteOffset: 8, as: UnsafeMutableRawPointer?.self)
        surface = pointer.map { Unmanaged<IOSurfaceRef>.fromOpaque($0).takeUnretainedValue() }
        width = Int(raw.load(fromByteOffset: 16, as: Int32.self))
        height = Int(raw.load(fromByteOffset: 20, as: Int32.self))
        letterboxed = raw.load(fromByteOffset: 32, as: Int32.self) != 0
    }
}

// MARK: C entries (the CEF UI thread, which is the main thread)

private let osrViewRect: @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafeMutablePointer<Int32>?,
                                         UnsafeMutablePointer<Int32>?) -> Void = { _, browser, width, height in
    guard Thread.isMainThread else { return }
    let size = MainActor.assumeIsolated { CEFOffscreenPages.shared.page(browser)?.pageSize } ?? .zero // main-proof: guarded by Thread.isMainThread above
    width?.pointee = Int32(max(1, size.width))
    height?.pointee = Int32(max(1, size.height))
}

private let osrScreenInfo: @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafeMutablePointer<Float>?,
                                           UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?) -> Int32 = {
    _, browser, scale, rect, available in
    guard Thread.isMainThread else { return 0 }
    return MainActor.assumeIsolated { // main-proof: guarded by Thread.isMainThread above
        guard let page = CEFOffscreenPages.shared.page(browser) else { return 0 }
        scale?.pointee = Float(page.backingScale)
        // The screen is the page's own view, as cefclient's: Chromium keeps its popups (<select>, the date picker)
        // inside it, so they are drawn in this layer and move with the pane.
        let size = page.pageSize
        for target in [rect, available] {
            target?[0] = 0
            target?[1] = 0
            target?[2] = Int32(max(1, size.width))
            target?[3] = Int32(max(1, size.height))
        }
        return 1
    }
}

private let osrScreenPoint: @convention(c) (UnsafeMutableRawPointer?, Int32, Int32, Int32, UnsafeMutablePointer<Int32>?,
                                            UnsafeMutablePointer<Int32>?) -> Int32 = { _, browser, x, y, screenX, screenY in
    guard Thread.isMainThread else { return 0 }
    return MainActor.assumeIsolated { // main-proof: guarded by Thread.isMainThread above
        guard let point = CEFOffscreenPages.shared.page(browser)?.screenPoint(x: Int(x), y: Int(y)) else { return 0 }
        screenX?.pointee = Int32(point.x.rounded())
        screenY?.pointee = Int32(point.y.rounded())
        return 1
    }
}

private let osrFrame: @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafeRawPointer?) -> Void = { _, browser, raw in
    guard Thread.isMainThread, let raw else { return }
    let frame = CEFOffscreenFrame(raw)
    MainActor.assumeIsolated { CEFOffscreenPages.shared.frameArrived(frame, browser: browser) } // main-proof: guarded by Thread.isMainThread above
}

private let osrPopupShow: @convention(c) (UnsafeMutableRawPointer?, Int32, Int32) -> Void = { _, browser, show in
    guard Thread.isMainThread else { return }
    MainActor.assumeIsolated { CEFOffscreenPages.shared.page(browser)?.popupShown(show != 0) } // main-proof: guarded by Thread.isMainThread above
}

private let osrPopupRect: @convention(c) (UnsafeMutableRawPointer?, Int32, Int32, Int32, Int32, Int32) -> Void = {
    _, browser, x, y, width, height in
    guard Thread.isMainThread else { return }
    let rect = CGRect(x: Int(x), y: Int(y), width: Int(width), height: Int(height))
    MainActor.assumeIsolated { CEFOffscreenPages.shared.page(browser)?.popupRect = rect } // main-proof: guarded by Thread.isMainThread above
}

private let osrImeRange: @convention(c) (UnsafeMutableRawPointer?, Int32, Int32, Int32, UnsafePointer<Int32>?, Int32) -> Void = {
    _, browser, from, to, rects, count in
    guard Thread.isMainThread else { return }
    var bounds: [CGRect] = []
    if let rects, count > 0 {
        for index in 0..<Int(count) {
            let base = index * 4
            bounds.append(CGRect(x: Int(rects[base]), y: Int(rects[base + 1]), width: Int(rects[base + 2]),
                                 height: Int(rects[base + 3])))
        }
    }
    MainActor.assumeIsolated { // main-proof: guarded by Thread.isMainThread above
        CEFOffscreenPages.shared.page(browser)?.compositionChanged(from: Int(from), to: Int(to), bounds: bounds)
    }
}

private let osrCursor: @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafeMutableRawPointer?) -> Void = { _, browser, cursor in
    guard Thread.isMainThread, let cursor else { return }
    let address = UInt(bitPattern: cursor)
    MainActor.assumeIsolated { // main-proof: guarded by Thread.isMainThread above
        guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return }
        CEFOffscreenPages.shared.page(browser)?.cursorChanged(Unmanaged<NSCursor>.fromOpaque(pointer).takeUnretainedValue())
    }
}

/// `cmux_shim_osr_handlers`: eight function pointers in its field order (the shim copies the struct).
private func makeHandlerTable() -> UnsafeMutablePointer<UnsafeRawPointer?> {
    let table = UnsafeMutablePointer<UnsafeRawPointer?>.allocate(capacity: 8)
    table[0] = unsafeBitCast(osrViewRect, to: UnsafeRawPointer.self)
    table[1] = unsafeBitCast(osrScreenInfo, to: UnsafeRawPointer.self)
    table[2] = unsafeBitCast(osrScreenPoint, to: UnsafeRawPointer.self)
    table[3] = unsafeBitCast(osrFrame, to: UnsafeRawPointer.self)
    table[4] = unsafeBitCast(osrPopupShow, to: UnsafeRawPointer.self)
    table[5] = unsafeBitCast(osrPopupRect, to: UnsafeRawPointer.self)
    table[6] = unsafeBitCast(osrImeRange, to: UnsafeRawPointer.self)
    table[7] = unsafeBitCast(osrCursor, to: UnsafeRawPointer.self)
    return table
}

// MARK: The process's off-screen pages

/// Every off-screen page of the process: the shim's handlers, the page views by browser, the tabs whose browser is
/// being made, and the resize wait (each resize step's frame at the new size, waited for before Core Animation commits
/// the step).
final class CEFOffscreenPages {
    static let shared = CEFOffscreenPages()

    init() {}

    private(set) var calls: CEFOffscreenShim?
    /// External begin frames: each page draws only when cmux sends it a begin frame (its display link, and at once
    /// after a resize). `CMUX_OSR_BEGIN_FRAMES=external`.
    private(set) var externalBeginFrames = false
    private var pages: [Int32: WeakOffscreenPage] = [:]
    /// Tabs whose off-screen browser is being made, by the request their AFTER_CREATED reports.
    private var pendingTabs: [Int32: WeakCEFTab] = [:]
    private var resizeObserver: MainRunLoopObserver?
    private var displayLink: CADisplayLink?

    /// How long a resize step waits, before Core Animation commits it, for each resized page's frame at the new size
    /// (`CMUX_OSR_RESIZE_WAIT_MS`, 0 to 100; default 16). 0 shows the last frame, pinned top-left, until the new one.
    let resizeWaitMs: Double = {
        let value = ProcessInfo.processInfo.environment["CMUX_OSR_RESIZE_WAIT_MS"].flatMap(Double.init) ?? 16
        return min(100, max(0, value))
    }()

    // `debug.cef` `offscreen`.
    private(set) var stats = Stats()
    struct Stats {
        var framesShown = 0
        var popupFramesShown = 0
        var letterboxedDropped = 0
        var resizes = 0
        /// Resize steps whose frame at the new size came inside the wait (shown with the step's own commit).
        var waitHits = 0
        /// Steps whose frame did not come in the wait (the step committed with the last frame, pinned top-left).
        var waitMisses = 0
        var waitMsTotal = 0.0
        /// The latest resize-to-frame times, ms (each resize until its frame at the new size).
        var resizeToFrameMs: [Double] = []
        var beginFrames = 0
    }

    /// Whether this process makes its pages off screen: the switch is on and the shim has the calls.
    var isOn: Bool { calls != nil }

    /// Before CefInitialize: turns windowless rendering on when the switch asks and the shim has the calls.
    func enable(shim: CEFShimLibrary) {
        guard InTreePages.shared.isOffscreenRequested else { return }
        guard let calls = shim.offscreen else {
            offscreenLogger.error("off-screen pages asked for, but the shim lacks the calls: windowed pages")
            return
        }
        externalBeginFrames = ProcessInfo.processInfo.environment["CMUX_OSR_BEGIN_FRAMES"] == "external"
        calls.enable(1, externalBeginFrames ? 1 : 0)
        let table = makeHandlerTable()
        calls.setHandlers(UnsafeRawPointer(table), nil)
        table.deallocate()
        self.calls = calls
        offscreenLogger.info("off-screen pages on (begin frames \(self.externalBeginFrames ? "external" : "internal", privacy: .public), resize wait \(self.resizeWaitMs, privacy: .public) ms)")
    }

    func page(_ browser: Int32) -> CEFOffscreenPageView? {
        pages[browser]?.page
    }

    func register(_ page: CEFOffscreenPageView) {
        pages[page.browser] = WeakOffscreenPage(page)
        updateDisplayLink()
    }

    func unregister(_ page: CEFOffscreenPageView) {
        if pages[page.browser]?.page === page { pages[page.browser] = nil }
        updateDisplayLink()
    }

    /// A tab of a live pane window: its own off-screen browser (Alloy pages have no tab strip to join).
    func createTab(_ tab: CEFTab, in host: CEFPaneHost, url: String?, contextKey: String) -> Bool {
        guard let calls else { return false }
        let request = host.runtime.makeRequestToken()
        pendingTabs[request] = WeakCEFTab(tab)
        let size = CEFPaneHost.creationSize(for: host.hostView.bounds.size)
        let made = calls.create(request, Unmanaged.passUnretained(host.hostView).toOpaque(),
                                max(size.width, 1).clampedInt32, max(size.height, 1).clampedInt32, url, contextKey, 0)
        if made != 1 { pendingTabs[request] = nil }
        return made == 1
    }

    /// AFTER_CREATED of a tab's own off-screen browser (`createTab`): the tab, once.
    func takePendingTab(request: Int32) -> CEFTab? {
        guard request != 0 else { return nil }
        return pendingTabs.removeValue(forKey: request)?.tab
    }

    func frameArrived(_ frame: CEFOffscreenFrame, browser: Int32) {
        guard let page = page(browser) else { return }
        if frame.letterboxed {
            stats.letterboxedDropped += 1
            return
        }
        guard let surface = frame.surface else { return }
        if frame.isPopup {
            stats.popupFramesShown += 1
        } else {
            stats.framesShown += 1
        }
        page.show(surface, width: frame.width, height: frame.height, popup: frame.isPopup)
    }

    // MARK: Resize wait

    /// `page` resized in this turn: before Core Animation commits the turn, wait up to ``resizeWaitMs`` for its frame
    /// at the new size, pumping Chromium's work, so the pane's new size and the page's pixels at it show in one commit.
    func awaitFrame(_ page: CEFOffscreenPageView) {
        stats.resizes += 1
        if externalBeginFrames { beginFrame(page.browser) }
        guard resizeObserver == nil else { return }
        // Just before the frame probe (1,999,998), the frame presenter (1,999,999) and Core Animation's commit
        // (2,000,000): after the turn's layout.
        resizeObserver = MainRunLoopObserver(activities: .beforeWaiting, order: 1_999_997) { [weak self] _ in
            self?.drainResizes()
        }
    }

    private func drainResizes() { // perf-hot: up to CMUX_OSR_RESIZE_WAIT_MS per resize step (the off-screen resize wait)
        let waiting = pages.values.compactMap(\.page).filter(\.awaitsFrame)
        guard !waiting.isEmpty else {
            resizeObserver = nil
            return
        }
        // A resize inside AppKit's layout pass (after this observer) waits in the next turn.
        let started = CACurrentMediaTime()
        let deadline = started + resizeWaitMs / 1_000
        if resizeWaitMs > 0 {
            while waiting.contains(where: \.awaitsFrame), CACurrentMediaTime() < deadline {
                CEFRuntime.shared.pump?.pumpNow()
                if waiting.contains(where: \.awaitsFrame) { usleep(250) }
            }
        }
        stats.waitMsTotal += (CACurrentMediaTime() - started) * 1_000
        for page in waiting {
            if page.awaitsFrame { stats.waitMisses += 1 } else { stats.waitHits += 1 }
        }
    }

    func resizeReachedFrame(afterMs ms: Double) {
        stats.resizeToFrameMs.append(ms)
        if stats.resizeToFrameMs.count > 2_000 { stats.resizeToFrameMs.removeFirst(stats.resizeToFrameMs.count - 2_000) }
    }

    // MARK: External begin frames

    private func beginFrame(_ browser: Int32) {
        calls?.beginFrame(browser)
        stats.beginFrames += 1
    }

    private func updateDisplayLink() {
        guard externalBeginFrames else { return }
        let live = pages.values.compactMap(\.page)
        if live.isEmpty {
            displayLink?.invalidate()
            displayLink = nil
            return
        }
        guard displayLink == nil, let view = live.first(where: { $0.window != nil }) else { return }
        let link = view.displayLink(target: CEFOffscreenDisplayTick.shared, selector: #selector(CEFOffscreenDisplayTick.tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    fileprivate func displayTicked() {
        for page in pages.values.compactMap(\.page) where page.isDrawing { beginFrame(page.browser) }
    }

    /// `debug.cef` `offscreen`: numbers by name (nil percentiles are left out).
    var debugNumbers: [String: Double] {
        var shim: [UInt64] = Array(repeating: 0, count: 8)
        shim.withUnsafeMutableBufferPointer { calls?.counters($0.baseAddress, 8) }
        let sorted = stats.resizeToFrameMs.sorted()
        func percentile(_ p: Double) -> Double? {
            sorted.isEmpty ? nil : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
        }
        var fields: [String: Double] = [
            "on": isOn ? 1 : 0,
            "external_begin_frames": externalBeginFrames ? 1 : 0,
            "resize_wait_ms": resizeWaitMs,
            "pages": Double(pages.values.compactMap(\.page).count),
            "frames_shown": Double(stats.framesShown),
            "popup_frames_shown": Double(stats.popupFramesShown),
            "letterboxed_dropped": Double(stats.letterboxedDropped),
            "resizes": Double(stats.resizes),
            "wait_hits": Double(stats.waitHits),
            "wait_misses": Double(stats.waitMisses),
            "wait_ms_total": stats.waitMsTotal,
            "resize_to_frame_samples": Double(sorted.count),
            "begin_frames_sent": Double(stats.beginFrames),
            "shim_frames": Double(shim[0]), "shim_letterboxed": Double(shim[1]), "shim_blit_us_total": Double(shim[2]),
            "shim_refreshes": Double(shim[3]), "shim_popup_frames": Double(shim[4]), "shim_blit_failures": Double(shim[5]),
            "shim_surfaces_made": Double(shim[6]), "shim_offscreen_browsers": Double(shim[7]),
        ]
        fields["resize_to_frame_ms_p50"] = percentile(0.5)
        fields["resize_to_frame_ms_p95"] = percentile(0.95)
        fields["resize_to_frame_ms_max"] = sorted.last
        return fields
    }

    /// Clears the counters (a bench run's start).
    func resetStats() {
        stats = Stats()
    }
}

/// The display link's target (a display link holds its target strongly).
final class CEFOffscreenDisplayTick: NSObject {
    static let shared = CEFOffscreenDisplayTick()

    @objc func tick(_ link: CADisplayLink) {
        CEFOffscreenPages.shared.displayTicked()
    }
}

struct WeakOffscreenPage {
    weak var page: CEFOffscreenPageView?
    init(_ page: CEFOffscreenPageView) { self.page = page }
}

// MARK: One host view's pages

/// The off-screen pages over one ``CEFHostView``: a page view per browser of the pane (each tab has its own browser),
/// the shown tab's unhidden.
final class CEFOffscreenHosting {
    weak var view: CEFHostView?
    private var pages: [Int32: CEFOffscreenPageView] = [:]
    private(set) var shown: Int32?

    /// Whether this host's pages are off screen (the process's switch).
    var isActive: Bool { CEFOffscreenPages.shared.isOn }

    /// A browser of this pane came up; true when it is off screen (it gets a page view).
    @discardableResult
    func pageCreated(browser: Int32) -> Bool {
        guard let calls = CEFOffscreenPages.shared.calls, calls.isOffscreen(browser) == 1 else { return false }
        _ = page(for: browser, calls: calls)
        return true
    }

    /// The shown tab's page: its view shows (made when this pane never had it: a page another page opened), the rest
    /// hide (Chromium hears `WasHidden` for each).
    func pageShown(browser: Int32) {
        guard let calls = CEFOffscreenPages.shared.calls, calls.isOffscreen(browser) == 1 else { return }
        shown = browser
        let page = page(for: browser, calls: calls)
        for (id, other) in pages where id != browser { other.isHidden = true }
        if page.isHidden { page.isHidden = false }
    }

    func page(of browser: Int32) -> CEFOffscreenPageView? { pages[browser] }

    var shownPage: CEFOffscreenPageView? { shown.flatMap { pages[$0] } }

    /// The browser closed.
    func pageClosed(browser: Int32) {
        guard let page = pages.removeValue(forKey: browser) else { return }
        page.close()
        if shown == browser { shown = nil }
    }

    /// The host's view goes away.
    func stop() {
        for page in pages.values { page.close() }
        pages.removeAll()
        shown = nil
    }

    /// cmux gives the shown page the keyboard (`CEFTab.grantFocus`): Chromium's focus and the page view as the window's
    /// first responder, inside one grant the window's gate lets through.
    @discardableResult
    func grantFocus(browser: Int32, _ focus: () -> Void) -> Bool {
        guard let page = pages[browser], let window = page.window else { return false }
        return InTreePageFocus.shared.granting(page) {
            focus()
            if window.firstResponder === page { return true }
            return FocusRoute(.person, "cmux grants an off-screen page the keyboard").moveKeyboard(in: window, to: page)
        }
    }

    private func page(for browser: Int32, calls: CEFOffscreenShim) -> CEFOffscreenPageView {
        if let page = pages[browser] { return page }
        let made = CEFOffscreenPageView(browser: browser, calls: calls)
        if let view {
            made.frame = CEFInTreePageView.wholePointFrame(in: view.bounds, flipped: view.isFlipped)
            // Below every other subview of the host (the tracker's probe), as an in-tree page is.
            view.addSubview(made, positioned: .below, relativeTo: nil)
        }
        made.isHidden = shown != nil && shown != browser
        pages[browser] = made
        CEFOffscreenPages.shared.register(made)
        return made
    }
}

// MARK: The page view

/// One off-screen page in its pane: its frames as this view's layer contents (pinned top-left, never stretched), its
/// `<select>` and date pop-ups as a sublayer at their rect, and every input event turned into Chromium's by hand.
final class CEFOffscreenPageView: NSView, InTreePageContainer, NSTextInputClient {
    let browser: Int32
    private let calls: CEFOffscreenShim
    private let content = CALayer()
    private let popupLayer = CALayer()
    private var tracking: NSTrackingArea?
    private var occlusionObserver: (any NSObjectProtocol)?
    private var cursor: NSCursor?
    private var closed = false

    /// The size Chromium lays the page out at: whole points (GetViewRect).
    private(set) var pageSize = CGSize(width: 1, height: 1)
    /// The pixel size of the last frame shown.
    private var shownPixels = CGSize.zero
    /// The pixel size a resize waits for, and when it began (`CEFOffscreenPages.awaitFrame`).
    private var awaitedPixels: CGSize?
    private var resizeStarted: CFTimeInterval = 0

    var inTreeCensus: InTreePageCensus { InTreePageCensus(contentInWindow: window != nil, widgetDrawing: 0) }

    init(browser: Int32, calls: CEFOffscreenShim) {
        self.browser = browser
        self.calls = calls
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        content.contentsGravity = .topLeft
        content.actions = Self.noActions
        content.frame = bounds
        content.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        popupLayer.actions = Self.noActions
        popupLayer.isHidden = true
        popupLayer.contentsGravity = .topLeft
        layer?.addSublayer(content)
        layer?.addSublayer(popupLayer)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var backingScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    /// Whether Chromium should draw this page now (shown, in a window that is on screen).
    var isDrawing: Bool {
        guard !closed, let window, !isHiddenOrHasHiddenAncestor else { return false }
        return window.occlusionState.contains(.visible)
    }

    var awaitsFrame: Bool { awaitedPixels != nil }

    func close() {
        closed = true
        CEFOffscreenPages.shared.unregister(self)
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        removeFromSuperview()
    }

    // MARK: Geometry

    /// The host resized: the page takes its whole-point frame, as an in-tree page does.
    override func resize(withOldSuperviewSize oldSize: NSSize) {
        guard let superview else { return super.resize(withOldSuperviewSize: oldSize) }
        let fitted = CEFInTreePageView.wholePointFrame(in: superview.bounds, flipped: superview.isFlipped)
        if frame != fitted { frame = fitted }
    }

    override func setFrameSize(_ newSize: NSSize) { // perf-hot: one WasResized per off-screen page per resize step
        super.setFrameSize(newSize)
        let size = CGSize(width: max(1, newSize.width.rounded(.down)), height: max(1, newSize.height.rounded(.down)))
        guard size != pageSize, !closed else { return }
        pageSize = size
        calls.wasResized(browser)
        let pixels = CGSize(width: (size.width * backingScale).rounded(), height: (size.height * backingScale).rounded())
        guard pixels != shownPixels else { return }
        if awaitedPixels == nil { resizeStarted = CACurrentMediaTime() }
        awaitedPixels = pixels
        CEFOffscreenPages.shared.awaitFrame(self)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = backingScale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.contentsScale = scale
        popupLayer.contentsScale = scale
        CATransaction.commit()
        calls.screenInfoChanged(browser)
        calls.wasResized(browser)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        if let window {
            occlusionObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                                       object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateHidden() } // main-proof: queue .main
            }
            content.contentsScale = backingScale
            popupLayer.contentsScale = backingScale
            calls.screenInfoChanged(browser)
        }
        updateHidden()
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateHidden()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateHidden()
    }

    private var reportedHidden: Bool?

    /// Chromium draws only a page on screen: hidden, out of a window or in a covered window, it hears `WasHidden`. The
    /// last frame stays in this layer, so the page shows at once when it comes back.
    private func updateHidden() {
        guard !closed else { return }
        let hidden = !isDrawing
        guard hidden != reportedHidden else { return }
        reportedHidden = hidden
        calls.wasHidden(browser, hidden ? 1 : 0)
        if !hidden { calls.invalidate(browser) }
    }

    /// A view point (DIP, top-left origin) in screen coordinates (Cocoa's, bottom-left origin), as cefclient's.
    func screenPoint(x: Int, y: Int) -> CGPoint? {
        guard let window else { return nil }
        let local = NSPoint(x: CGFloat(x), y: bounds.height - CGFloat(y))
        return window.convertPoint(toScreen: convert(local, to: nil))
    }

    // MARK: Frames

    func show(_ surface: IOSurfaceRef, width: Int, height: Int, popup: Bool) { // perf-hot: each off-screen frame
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if popup {
            popupLayer.contents = surface
        } else {
            content.contents = surface
        }
        CATransaction.commit()
        guard !popup else { return }
        shownPixels = CGSize(width: width, height: height)
        if let awaited = awaitedPixels, awaited == shownPixels {
            awaitedPixels = nil
            CEFOffscreenPages.shared.resizeReachedFrame(afterMs: (CACurrentMediaTime() - resizeStarted) * 1_000)
        }
    }

    func popupShown(_ show: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        popupLayer.isHidden = !show
        if !show { popupLayer.contents = nil }
        CATransaction.commit()
    }

    /// The pop-up's rect in the page (DIP, top-left origin).
    var popupRect: CGRect = .zero {
        didSet {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            popupLayer.frame = CGRect(x: popupRect.minX, y: bounds.height - popupRect.maxY,
                                      width: popupRect.width, height: popupRect.height)
            CATransaction.commit()
        }
    }

    // MARK: Cursor

    func cursorChanged(_ cursor: NSCursor) {
        self.cursor = cursor
        guard let window, window.isKeyWindow else { return }
        let local = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if bounds.contains(local) { cursor.set() }
    }

    override func cursorUpdate(with event: NSEvent) {
        if let cursor { cursor.set() } else { super.cursorUpdate(with: event) }
    }

    // MARK: Focus

    override func becomeFirstResponder() -> Bool {
        CEFRuntime.shared.shim?.setFocus(browser, 1)
        return true
    }

    override func resignFirstResponder() -> Bool {
        if hasMarked { unmarkText() }
        CEFRuntime.shared.shim?.setFocus(browser, 0)
        return true
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = nil
        guard !isServedByPanePointerArea else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect,
                                                         .cursorUpdate], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        mouse(event, kind: 2, button: 0)
    }
    override func mouseUp(with event: NSEvent) { mouse(event, kind: 3, button: 0) }
    override func rightMouseDown(with event: NSEvent) {
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        mouse(event, kind: 2, button: 2)
    }
    override func rightMouseUp(with event: NSEvent) { mouse(event, kind: 3, button: 2) }
    override func otherMouseDown(with event: NSEvent) { mouse(event, kind: 2, button: 1) }
    override func otherMouseUp(with event: NSEvent) { mouse(event, kind: 3, button: 1) }
    override func mouseMoved(with event: NSEvent) { mouse(event, kind: 0, button: 0) }
    override func mouseDragged(with event: NSEvent) { mouse(event, kind: 0, button: 0) }
    override func rightMouseDragged(with event: NSEvent) { mouse(event, kind: 0, button: 2) }
    override func otherMouseDragged(with event: NSEvent) { mouse(event, kind: 0, button: 1) }
    override func mouseEntered(with event: NSEvent) { mouse(event, kind: 0, button: 0) }
    override func mouseExited(with event: NSEvent) { mouse(event, kind: 1, button: 0) }

    private func mouse(_ event: NSEvent, kind: Int32, button: Int32) { // perf-hot: each mouse event over a page
        let point = pagePoint(event.locationInWindow)
        let clicks = kind == 2 || kind == 3 ? Int32(event.clickCount) : 0
        calls.mouse(browser, kind, point.x, point.y, Self.modifiers(event), button, clicks)
    }

    override func scrollWheel(with event: NSEvent) { // perf-hot: each scroll event over a page
        let point = pagePoint(event.locationInWindow)
        // Pixel deltas, as cefclient's off-screen view reads them. No phase or momentum reaches Chromium (the API has
        // none): no rubber band at the page's ends.
        let cgEvent = event.cgEvent
        let dy = cgEvent.map { Int32($0.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)) } ?? 0
        let dx = cgEvent.map { Int32($0.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)) } ?? 0
        var modifiers = Self.modifiers(event)
        if event.hasPreciseScrollingDeltas { modifiers |= Flags.precisionScrolling }
        calls.wheel(browser, point.x, point.y, modifiers, dx, dy)
    }

    /// A window point in page coordinates: points from the top left.
    private func pagePoint(_ windowPoint: NSPoint) -> (x: Int32, y: Int32) {
        let local = convert(windowPoint, from: nil)
        return (Int32(local.x.rounded(.down)), Int32((bounds.height - local.y).rounded(.down)))
    }

    // MARK: Keys (cefclient's text_input_client_osr_mac.mm order)

    private var handlingKey = false
    private var wasMarkedAtKey = false
    private var insertedText = ""
    private var markedText = ""
    private var hasMarked = false
    private var markedSelection = NSRange(location: NSNotFound, length: 0)
    private var markedReplacement = NSRange(location: NSNotFound, length: 0)
    private var unmarkCalled = false
    private var compositionRange = NSRange(location: NSNotFound, length: 0)
    private var compositionBounds: [CGRect] = []

    override func keyDown(with event: NSEvent) { // perf-hot: each key typed into a page
        wasMarkedAtKey = hasMarked
        handlingKey = true
        insertedText = ""
        unmarkCalled = false
        markedReplacement = NSRange(location: NSNotFound, length: 0)
        _ = inputContext?.handleEvent(event)
        handlingKey = false
        let fields = Self.keyFields(event)
        // One character typed with no composition: the key and its character, as Chromium's own view sends them.
        if !hasMarked, !wasMarkedAtKey, insertedText.utf16.count <= 1 {
            calls.key(browser, 1, fields.modifiers, fields.code, fields.character, fields.unmodified)
            if !(fields.modifiers & Flags.keypad != 0 && event.keyCode == 71) {
                calls.key(browser, 3, fields.modifiers, fields.code, fields.character, fields.unmodified)
            }
        }
        // More text, or text that ends a composition: committed as text.
        if insertedText.utf16.count > ((hasMarked || wasMarkedAtKey) ? 0 : 1) {
            insertedText.withCString { calls.imeCommit(browser, $0, -1, -1, 0) }
            insertedText = ""
        }
        if hasMarked, !markedText.isEmpty {
            let replace = Self.range(markedReplacement)
            let selection = Self.range(NSRange(location: markedSelection.location, length: markedSelection.length))
            markedText.withCString { calls.imeSetComposition(browser, $0, replace.0, replace.1, selection.0, selection.1) }
        } else if wasMarkedAtKey, !hasMarked, insertedText.isEmpty {
            if unmarkCalled { calls.imeFinish(browser, 0) } else { calls.imeCancel(browser) }
        }
    }

    override func keyUp(with event: NSEvent) {
        let fields = Self.keyFields(event)
        calls.key(browser, 2, fields.modifiers, fields.code, fields.character, fields.unmodified)
    }

    override func flagsChanged(with event: NSEvent) {
        let fields = Self.keyFields(event)
        calls.key(browser, Self.isModifierRelease(event) ? 2 : 1, fields.modifiers, fields.code, 0, 0)
    }

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        if handlingKey {
            insertedText += text
        } else {
            let replace = Self.range(replacementRange)
            text.withCString { calls.imeCommit(browser, $0, replace.0, replace.1, 0) }
        }
        hasMarked = false
        markedText = ""
    }

    override func doCommand(by selector: Selector) {
        // Chromium runs the key's own editing command from the key event (no beep, no AppKit text view behaviour).
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        markedText = text
        hasMarked = !text.isEmpty
        markedSelection = selectedRange
        if handlingKey {
            markedReplacement = replacementRange
        } else {
            let replace = Self.range(replacementRange)
            let selection = Self.range(selectedRange)
            text.withCString { calls.imeSetComposition(browser, $0, replace.0, replace.1, selection.0, selection.1) }
        }
    }

    func unmarkText() {
        hasMarked = false
        markedText = ""
        if handlingKey { unmarkCalled = true } else { calls.imeFinish(browser, 0) }
    }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func markedRange() -> NSRange {
        hasMarked ? NSRange(location: compositionRange.location == NSNotFound ? 0 : compositionRange.location,
                            length: markedText.utf16.count) : NSRange(location: NSNotFound, length: 0)
    }

    func hasMarkedText() -> Bool { hasMarked }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.underlineStyle, .underlineColor, .markedClauseSegment]
    }

    /// The IME's candidate window sits under the composition's character (`OnImeCompositionRangeChanged`).
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        var index = range.location == NSNotFound ? 0 : range.location
        if compositionRange.location != NSNotFound, index >= compositionRange.location { index -= compositionRange.location }
        let rect = index < compositionBounds.count ? compositionBounds[index] : (compositionBounds.last ?? .zero)
        actualRange?.pointee = NSRange(location: index, length: range.length)
        guard let window else { return .zero }
        let local = NSRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height)
        return window.convertToScreen(convert(local, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    func compositionChanged(from: Int, to: Int, bounds: [CGRect]) {
        compositionRange = from >= 0 ? NSRange(location: from, length: max(0, to - from)) : NSRange(location: NSNotFound, length: 0)
        compositionBounds = bounds
    }

    // MARK: Edit menu

    @objc func copy(_ sender: Any?) { calls.edit(browser, 3) }
    @objc func cut(_ sender: Any?) { calls.edit(browser, 2) }
    @objc func paste(_ sender: Any?) { calls.edit(browser, 4) }
    @objc func pasteAsPlainText(_ sender: Any?) { calls.edit(browser, 7) }
    @objc func delete(_ sender: Any?) { calls.edit(browser, 5) }
    @objc override func selectAll(_ sender: Any?) { calls.edit(browser, 6) }
    @objc func undo(_ sender: Any?) { calls.edit(browser, 0) }
    @objc func redo(_ sender: Any?) { calls.edit(browser, 1) }

    // MARK: Files dragged in

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let paths = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            as? [URL] ?? []).map(\.path)
        return drag(sender, kind: 0, paths: paths)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { drag(sender, kind: 1, paths: []) }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        _ = calls.drag(browser, 2, 0, 0, 0, nil, 0, 0)
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        _ = drag(sender, kind: 3, paths: [])
        return true
    }

    private func drag(_ info: any NSDraggingInfo, kind: Int32, paths: [String]) -> NSDragOperation {
        let point = pagePoint(info.draggingLocation)
        // cef_drag_operations_mask_t: copy 1, link 2, generic 4, private 8, move 16, delete 32 (NSDragOperation's bits).
        let allowed = Int32(truncatingIfNeeded: info.draggingSourceOperationMask.rawValue & 0x3F)
        let modifiers = Self.modifiers(flags: NSEvent.modifierFlags)
        let duplicated = paths.map { strdup($0) }
        defer { duplicated.forEach { free($0) } }
        let list: [UnsafePointer<CChar>?] = duplicated.map { $0.map { UnsafePointer($0) } }
        let taken = list.withUnsafeBufferPointer { buffer in
            calls.drag(browser, kind, point.x, point.y, modifiers, list.isEmpty ? nil : buffer.baseAddress, Int32(list.count), allowed)
        }
        return NSDragOperation(rawValue: UInt(max(0, taken)))
    }

    // MARK: Event fields

    enum Flags {
        static let capsLock: UInt32 = 1 << 0
        static let shift: UInt32 = 1 << 1
        static let control: UInt32 = 1 << 2
        static let alt: UInt32 = 1 << 3
        static let leftMouse: UInt32 = 1 << 4
        static let middleMouse: UInt32 = 1 << 5
        static let rightMouse: UInt32 = 1 << 6
        static let command: UInt32 = 1 << 7
        static let keypad: UInt32 = 1 << 9
        static let precisionScrolling: UInt32 = 1 << 14
    }

    /// cef_event_flags_t of an event, as cefclient's `getModifiersForEvent`.
    static func modifiers(_ event: NSEvent) -> UInt32 {
        var flags = modifiers(flags: event.modifierFlags)
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged: flags |= Flags.leftMouse
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged: flags |= Flags.rightMouse
        case .otherMouseDown, .otherMouseUp, .otherMouseDragged: flags |= Flags.middleMouse
        case .keyDown, .keyUp, .flagsChanged: if isKeypad(event) { flags |= Flags.keypad }
        default: break
        }
        return flags
    }

    static func modifiers(flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.control) { result |= Flags.control }
        if flags.contains(.shift) { result |= Flags.shift }
        if flags.contains(.option) { result |= Flags.alt }
        if flags.contains(.command) { result |= Flags.command }
        if flags.contains(.capsLock) { result |= Flags.capsLock }
        return result
    }

    private static func keyFields(_ event: NSEvent) -> (modifiers: UInt32, code: Int32, character: UInt16, unmodified: UInt16) {
        let typed = event.type == .keyDown || event.type == .keyUp
        return (modifiers(event), Int32(event.keyCode),
                typed ? (event.characters?.utf16.first ?? 0) : 0,
                typed ? (event.charactersIgnoringModifiers?.utf16.first ?? 0) : 0)
    }

    private static func isKeypad(_ event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.numericPad) { return true }
        return [71, 81, 75, 67, 78, 69, 76, 65, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92].contains(event.keyCode)
    }

    /// A modifier key's release (flagsChanged), as cefclient's `isKeyUpEvent`.
    private static func isModifierRelease(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        switch event.keyCode {
        case 54, 55: return !flags.contains(.command)
        case 57: return !flags.contains(.capsLock)
        case 56, 60: return !flags.contains(.shift)
        case 58, 61: return !flags.contains(.option)
        case 59, 62: return !flags.contains(.control)
        case 63: return !flags.contains(.function)
        default: return false
        }
    }

    /// An AppKit range as the shim's (from, to); NSNotFound is no range (-1).
    private static func range(_ range: NSRange) -> (Int32, Int32) {
        guard range.location != NSNotFound else { return (-1, -1) }
        return (Int32(clamping: range.location), Int32(clamping: range.location + range.length))
    }

    private static let noActions: [String: any CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "hidden": NSNull(), "frame": NSNull(),
    ]
}

/// In a pane the layout screen's one tracking area delivers the pointer's moves (as for ``ChromiumHostPageView``); the
/// page's cursor is the one Chromium set last.
extension CEFOffscreenPageView: PanePointerFollowing {
    func panePointerCursor(at point: NSPoint) -> NSCursor? { cursor }
    func panePointerEntered(with event: NSEvent) {}
    func panePointerMoved(with event: NSEvent) { if window?.isKeyWindow == true { mouseMoved(with: event) } }
    func panePointerExited(with event: NSEvent) { if window?.isKeyWindow == true { mouseExited(with: event) } }
}
