import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Foundation
import Testing

/// The Extensions menu opens and hovers within a frame budget (u2229: "this extensions context
/// menu is also extremely laggy", u2426: "menu visible within one frame"). Budgets: an open under 16 ms, the
/// first open under 50 ms, a hover under 16 ms, with 40 extensions, each scaled to the runner by its reference
/// workload (Budgets, FrameBudgetCalibration), or skipped with the reason printed on a runner too slow or noisy.
@MainActor @Suite(.serialized, .closesItsWindows) struct ExtensionsMenuPerformanceTests {
    static let count = 40

    static func iconFile(_ index: Int, in directory: URL) -> String {
        let size = 128
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(hue: CGFloat(index % 10) / 10, saturation: 0.7, brightness: 0.8, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 4, y: 4, width: 120, height: 120)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let url = directory.appendingPathComponent("icon-\(index).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        return url.path
    }

    static func tab(extensions count: Int = count) -> MockBrowserTab {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ext-menu-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com")))
        tab.showsExtensionToolbar = true
        tab.extensionBackend.extensions = (0..<count).map { index in
            BrowserExtensionInfo(id: "ext\(index)", name: "Extension \(index)", location: .webstore, hasAction: true,
                                 isPinned: index % 3 == 0, optionsURL: URL(string: "chrome-extension://ext\(index)/options.html"),
                                 iconPath: iconFile(index, in: directory))
        }
        tab.extensionStore.refresh()
        return tab
    }

    /// A bubble shows only in a window on a screen; a CI worker with no display has none.
    static func hasDisplay() -> Bool { !NSScreen.screens.isEmpty }

    /// Why a bubble did not show (printed when a test needs it).
    static func environment(_ window: NSWindow) -> String {
        "screens=\(NSScreen.screens.map(\.frame)) active=\(NSApp?.isActive ?? false) window=\(window.frame) visible=\(window.isVisible)"
    }

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    /// The main thread's CPU time for `body`: work elsewhere on the host (another app, the next job on a shared
    /// fleet runner) delays the main thread without adding to this. The wall clock counted those delays: under
    /// threads at the highest QoS taking every core, a 1 ms sidebar toggle read 70-90 ms (aws-m4pro-1, 2026-10-21).
    static func mainThreadCPU(_ body: () -> Void) -> Duration {
        func now() -> Duration {
            var spent = timespec()
            clock_gettime(CLOCK_THREAD_CPUTIME_ID, &spent)
            return .seconds(spent.tv_sec) + .nanoseconds(spent.tv_nsec)
        }
        let started = now()
        body()
        return now() - started
    }

    /// The suite's budgets, ms of main-thread CPU on the hosts they were set on, held to on this runner scaled
    /// by its reference workload (FrameBudgetCalibration): aws-m4pro-9, 3-4x slower at every sidebar frame
    /// too, read a 51.3 ms first open against 50 ms with no change in the code.
    struct Budgets {
        var open = 16.0, firstOpen = 50.0, hover = 16.0
        let calibration: FrameBudgetCalibration

        /// `nominal` ms, scaled to this runner.
        func scaled(_ nominal: Double) -> Double { calibration.budget(nominal) }

        /// Each timing over its scaled budget, described; empty when every one holds.
        func overruns(open measuredOpen: Double? = nil, firstOpen measuredFirst: Double? = nil, hover measuredHover: Double? = nil) -> [String] {
            var found: [String] = []
            func check(_ what: String, _ measured: Double?, _ nominal: Double) {
                guard let measured else { return }
                let limit = scaled(nominal)
                if measured >= limit {
                    found.append("\(what) took \(measured) ms, over \(nominal) ms scaled by \(calibration.factor) to \(limit) ms")
                }
            }
            check("an open and close", measuredOpen, open)
            check("the first open", measuredFirst, firstOpen)
            check("the slowest hover", measuredHover, hover)
            return found
        }
    }

    /// A slow runner, stood in deterministically as in SidebarScrollCostTests, with no screen, so it runs on
    /// every runner: every timed open and every reference sample does the reference work `slowdown` times.
    /// This host's own reference is nominal and its own unslowed opens set the budgets, so the host's speed
    /// cancels out. The slowed opens break those budgets as they are, and hold them once they scale by the
    /// slowed reference.
    @Test func aSlowRunnerScalesTheMenuBudgets() {
        let slowdown = 3
        func work(_ times: Int) { for _ in 0..<times { FrameBudgetCalibration.referenceWork() } }
        func opens(_ times: Int) -> [Double] { (0..<30).map { _ in FrameBudgetCalibration.cpuMs { work(times) } } }
        work(4) // warm up
        let nominalMs = FrameBudgetCalibration.percentile(opens(1), 0.5)
        let budget = 1.5 * FrameBudgetCalibration.percentile(opens(1), 0.95)
        var slow = FrameBudgetCalibration(nominalMs: nominalMs, reference: { work(slowdown) })
        slow.checkpoint()
        let slowed = FrameBudgetCalibration.percentile(opens(slowdown), 0.95)
        slow.checkpoint()
        print(String(format: "EXTENSIONS-MENU-CALIBRATION-TEST reference %.3f ms, budget %.3f ms, slowed p95 %.3f ms | ",
                     nominalMs, budget, slowed) + slow.summary)
        #expect(slowed > budget, "the stand-in runner is not slow enough to break an unscaled budget")
        if let reason = slow.skipReason { return print("EXTENSIONS-MENU-CALIBRATION-TEST skipped: \(reason)") }
        let budgets = Budgets(open: budget, firstOpen: budget, hover: budget, calibration: slow)
        let overruns = budgets.overruns(open: slowed, firstOpen: slowed, hover: slowed)
        #expect(overruns.isEmpty, "a runner \(slowdown)x slower at the reference: \(overruns.joined(separator: "; "))")
    }

    /// A runner at or faster than nominal keeps the budgets as they were set: 16 ms an open, 50 ms the first,
    /// 16 ms a hover.
    @Test func aFastRunnerKeepsTheMenuBudgets() {
        var fast = FrameBudgetCalibration(nominalMs: 1_000)
        fast.checkpoint()
        let budgets = Budgets(calibration: fast)
        #expect(fast.factor == 1, "\(fast.summary)")
        #expect([budgets.scaled(budgets.open), budgets.scaled(budgets.firstOpen), budgets.scaled(budgets.hover)] == [16, 50, 16])
        #expect(budgets.overruns(open: 15.9, firstOpen: 49.9, hover: 15.9).isEmpty)
        #expect(budgets.overruns(firstOpen: 51.3).count == 1)
    }

    /// A visible window with the Extensions button at its top right.
    static func window() -> (NSWindow, NSView) {
        // Inside the main screen, so the bubble below the anchor has room (CI workers run at
        // small virtual displays).
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        let size = NSSize(width: min(900, screen.width - 40), height: min(700, screen.height - 40))
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: screen.minX + 20, y: screen.minY + 20), size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let anchor = NSView(frame: NSRect(x: size.width - 40, y: size.height - 40, width: 28, height: 28))
        window.contentView?.addSubview(anchor)
        window.orderFrontRegardless()
        return (window, anchor)
    }

    /// The shortest of `runs` main-thread CPU timings: a shared CI worker adds load to some runs, never
    /// removes work, so the minimum is the closest to the code's own cost.
    static func fastest(_ runs: Int = 5, _ body: () -> Void) -> Duration {
        (0..<runs).map { _ in mainThreadCPU(body) }.min() ?? .zero
    }

    @Test(.enabled("a bubble needs a screen to show") { await Self.hasDisplay() })
    func fortyExtensionsOpenWithinAFrame() throws {
        let tab = Self.tab()
        let (window, anchor) = Self.window()
        defer { window.close() }
        let handler = ExtensionsMenu.DirectHandler(host: tab) { _ in }
        let controller = ExtensionsMenuController()
        defer { controller.closePanel() }
        var calibration = FrameBudgetCalibration()
        calibration.checkpoint()
        // The toolbar prepares the rows and the panel when a tab binds, off the click's path.
        let prepare = Self.mainThreadCPU { controller.prepare(host: tab) }
        let first = Self.mainThreadCPU { controller.show(host: tab, handler: handler, anchor: anchor) }
        try #require(controller.isShown, "\(Self.environment(window))")
        #expect(controller.content.rows.count == Self.count)
        controller.close()
        let open = Self.fastest {
            controller.show(host: tab, handler: handler, anchor: anchor)
            controller.close()
        }
        calibration.checkpoint()
        print("TOOLBAR-PERF extensions.prepare=\(Self.milliseconds(prepare)) ms extensions.firstOpen=\(Self.milliseconds(first)) ms "
              + "extensions.open=\(Self.milliseconds(open)) ms | \(calibration.summary)")
        if let reason = calibration.skipReason { return print("TOOLBAR-PERF skipped the extensions open budgets: \(reason)") }
        let overruns = Budgets(calibration: calibration).overruns(open: Self.milliseconds(open), firstOpen: Self.milliseconds(first))
        #expect(overruns.isEmpty, "\(overruns.joined(separator: "; "))")
    }

    @Test(.enabled("a bubble needs a screen to show") { await Self.hasDisplay() })
    func aReopenDecodesNoIconAgain() throws {
        let tab = Self.tab()
        let (window, anchor) = Self.window()
        defer { window.close() }
        let handler = ExtensionsMenu.DirectHandler(host: tab) { _ in }
        let controller = ExtensionsMenuController()
        defer { controller.closePanel() }
        controller.show(host: tab, handler: handler, anchor: anchor)
        try #require(controller.isShown, "\(Self.environment(window))")
        #expect(controller.icons.loads == Self.count)
        controller.close()
        controller.show(host: tab, handler: handler, anchor: anchor)
        #expect(controller.icons.loads == Self.count, "a reopen read icon files again")
        controller.close()
    }

    @Test(.enabled("a bubble needs a screen to show") { await Self.hasDisplay() })
    func hoveringARowRedrawsWithinAFrame() throws {
        let tab = Self.tab()
        let (window, anchor) = Self.window()
        defer { window.close() }
        let controller = ExtensionsMenuController()
        defer { controller.closePanel() }
        controller.show(host: tab, handler: ExtensionsMenu.DirectHandler(host: tab) { _ in }, anchor: anchor)
        try #require(controller.isShown, "\(Self.environment(window))")
        var calibration = FrameBudgetCalibration()
        calibration.checkpoint()
        let enter = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                                        windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        let exit = try #require(NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
                                                       windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        var hovers: [Duration] = []
        for row in controller.content.rows {
            let rep = try #require(row.bitmapImageRepForCachingDisplay(in: row.bounds))
            hovers.append(Self.fastest(3) {
                row.primary.mouseEntered(with: enter)
                row.cacheDisplay(in: row.bounds, to: rep)
                row.primary.mouseExited(with: exit)
            })
        }
        calibration.checkpoint()
        let slowest = hovers.max() ?? .zero
        controller.close()
        print("TOOLBAR-PERF extensions.hover.max=\(Self.milliseconds(slowest)) ms | \(calibration.summary)")
        if let reason = calibration.skipReason { return print("TOOLBAR-PERF skipped the extensions hover budget: \(reason)") }
        let overruns = Budgets(calibration: calibration).overruns(hover: Self.milliseconds(slowest))
        #expect(overruns.isEmpty, "\(overruns.joined(separator: "; "))")
    }

    @Test(.enabled("a bubble needs a screen to show") { await Self.hasDisplay() })
    func openingDoesNotWaitForChromium() throws {
        let tab = Self.tab()
        let (window, anchor) = Self.window()
        defer { window.close() }
        let before = tab.extensionBackend.snapshots
        let controller = ExtensionsMenuController()
        defer { controller.closePanel() }
        controller.show(host: tab, handler: ExtensionsMenu.DirectHandler(host: tab) { _ in }, anchor: anchor)
        try #require(controller.isShown, "\(Self.environment(window))")
        #expect(tab.extensionBackend.snapshots == before, "the open asked Chromium for the list before it showed")
        #expect(controller.renders == 1)
        controller.close()
    }
}
