import AppKit
import Foundation
import QuartzCore

#if DEBUG
/// DEBUG-only numbers per press into `CMUX_NAV_TIMINGS_LOG`: main-thread CPU
/// of the keypress turn and of the landing, keypress to first frame, frame
/// intervals and main-thread CPU per frame while moving, and how many
/// visible sidebar rows had no title on the first frame of a show.
/// `notifyutil -p com.cmuxterm.debug.sidebar-toggle` presses the toggle in
/// the frontmost window, so this runs without driving the pointer.
@MainActor
final class SidebarToggleSlideProbe: NSObject {
    static weak var current: SidebarToggleSlideProbe?
    private static var live: SidebarToggleSlideProbe?

    private let name: String
    private let visible: Bool
    private weak var window: NSWindow?
    private let startWall: CFTimeInterval
    private let startCPU = SidebarToggleSlideProbe.threadCPU()
    private var keypressCPU = 0.0
    private var landingCPU: Double?
    private var link: CADisplayLink?
    private var last: (wall: CFTimeInterval, cpu: Double)?
    private var firstFrameMs: Double?
    private var blankRows: Int?
    private var intervals: [Double] = []
    private var cpu: [Double] = []
    private var landedWall: CFTimeInterval?
    private var finished = false

    /// Leading edge, in window points, of the leftmost portal-hosted
    /// terminal: where AppKit has the terminal right now.
    static func terminalFrameX(in window: NSWindow) -> Double {
        guard let portal = TerminalWindowPortalRegistry.portalsByWindowId[ObjectIdentifier(window)] else { return -1 }
        let xs = portal.hostView.subviews
            .filter { !$0.isHidden && $0.alphaValue > 0 && $0.bounds.width > 1 }
            .map { $0.convert($0.bounds, to: nil).minX }
            .filter { $0 > 1 }
        return Double(xs.min() ?? 0)
    }

    /// Leading edge, in window points, of the leftmost Bonsplit pane
    /// container in the content root: where SwiftUI has laid the panes out.
    static func paneContainerX(in window: NSWindow) -> Double {
        var xs: [CGFloat] = []
        func walk(_ view: NSView) {
            if NSStringFromClass(type(of: view)).contains("SplitArrangedContainerView"), !view.isHiddenOrHasHiddenAncestor {
                xs.append(view.convert(view.bounds, to: nil).minX)
            }
            view.subviews.forEach(walk)
        }
        if let root = TerminalWindowPortalRegistry.portalsByWindowId[ObjectIdentifier(window)]?.installedReferenceView {
            walk(root)
        }
        return Double(xs.min() ?? -1)
    }

    static func threadCPU() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1_000_000
    }

    static func begin(visible: Bool, window: NSWindow, animator: SidebarToggleAnimator) -> SidebarToggleSlideProbe? {
        guard SidebarNavigationTimings.isEnabled, let view = window.contentView else { return nil }
        live?.finish()
        let probe = SidebarToggleSlideProbe(visible: visible, window: window)
        let link = view.displayLink(target: probe, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        probe.link = link
        live = probe
        current = probe
        return probe
    }

    private init(visible: Bool, window: NSWindow, name: String? = nil, since start: CFTimeInterval? = nil) {
        self.visible = visible
        self.name = name ?? (visible ? "toggle.show" : "toggle.hide")
        self.window = window
        self.startWall = start ?? CACurrentMediaTime()
        super.init()
    }

    /// The peek card's reveal, timed from the hover that asked for it.
    static func beginPeek(window: NSWindow, since hover: CFTimeInterval?) -> SidebarToggleSlideProbe? {
        guard SidebarNavigationTimings.isEnabled, let view = window.contentView else { return nil }
        live?.finish()
        let probe = SidebarToggleSlideProbe(visible: false, window: window, name: "peek.reveal", since: hover)
        let link = view.displayLink(target: probe, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        probe.link = link
        live = probe
        return probe
    }

    func keypressDidFinish() {
        keypressCPU = Self.threadCPU() - startCPU
    }

    func didLand(cpu: Double) {
        landingCPU = cpu
        landedWall = CACurrentMediaTime()
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = (wall: CACurrentMediaTime(), cpu: Self.threadCPU())
        if firstFrameMs == nil {
            firstFrameMs = (now.wall - startWall) * 1000
            if visible { blankRows = countBlankSidebarRows() }
        } else if let last {
            intervals.append((now.wall - last.wall) * 1000)
            cpu.append(now.cpu - last.cpu)
        }
        last = now
        if let landedWall, now.wall - landedWall > 0.15 { finish() }
        if now.wall - startWall > 2 { finish() }
    }

    private func countBlankSidebarRows() -> Int {
        guard let root = window?.contentView,
              let table = Self.sidebarTable(in: root) else { return -1 }
        // The rows the clip view shows, whether or not AppKit loaded them: a
        // row with no view counts as blank too.
        let shown = table.enclosingScrollView?.contentView.documentVisibleRect ?? table.bounds
        let range = table.rows(in: shown)
        var blank = 0
        for row in range.location..<(range.location + range.length) {
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) else {
                blank += 1
                continue
            }
            if NSStringFromClass(type(of: cell)).contains("WorkspaceRow"), !Self.hasText(cell) { blank += 1 }
        }
        return blank
    }

    private static func sidebarTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView,
           NSStringFromClass(type(of: table)).contains("Sidebar")
            || NSStringFromClass(type(of: table.enclosingScrollView?.superview ?? table)).contains("SidebarWorkspaceTable") {
            return table
        }
        for subview in view.subviews {
            if let table = sidebarTable(in: subview) { return table }
        }
        return nil
    }

    private static func hasText(_ view: NSView) -> Bool {
        if let field = view as? NSTextField, !field.isHidden, !field.stringValue.isEmpty { return true }
        return view.subviews.contains { hasText($0) }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        link?.invalidate()
        link = nil
        if Self.live === self { Self.live = nil }
        let period = 1000.0 / Double(max(1, window?.screen?.maximumFramesPerSecond ?? 60))
        let dropped = intervals.reduce(0) { $0 + max(0, Int(($1 / period).rounded()) - 1) }
        let f = { (value: Double) in String(format: "%.2f", value) }
        let average = intervals.isEmpty ? 0 : intervals.reduce(0, +) / Double(intervals.count)
        let moving = cpu.dropLast(landingCPU == nil ? 0 : 1)
        let cpuAverage = moving.isEmpty ? 0 : moving.reduce(0, +) / Double(moving.count)
        SidebarNavigationTimings.record(
            "nav.frames interaction=\(name) frames=\(intervals.count + 1) " +
            "keypressCpu=\(f(keypressCPU)) firstFrameMs=\(f(firstFrameMs ?? -1)) " +
            "landingCpu=\(f(landingCPU ?? -1)) landed=\(landingCPU == nil ? 0 : 1) " +
            "intervalAvg=\(f(average)) intervalMax=\(f(intervals.max() ?? 0)) dropped=\(dropped) period=\(f(period)) " +
            "movingCpuAvg=\(f(cpuAverage)) movingCpuMax=\(f(moving.max() ?? 0)) " +
            "blankRows=\(blankRows ?? -1)"
        )
        SidebarNavigationTimings.record(
            "nav.frames.detail interaction=\(name) intervals=" +
            intervals.map { String(format: "%.1f", $0) }.joined(separator: ",") +
            " cpu=" + cpu.map { String(format: "%.1f", $0) }.joined(separator: ",")
        )
    }

    private static func toggleIfFrontmost(_ animator: SidebarToggleAnimator) {
        let frontmost = NSApp.mainWindow ?? NSApp.orderedWindows.first { $0.isVisible && $0.contentView != nil }
        guard let window = animator.debugWindow, window === frontmost else { return }
        animator.debugSidebarState?.toggle()
    }

    private static var triggerTargets: [ObjectIdentifier: () -> SidebarToggleAnimator?] = [:]
    private static var isTriggerRegistered = false

    static func installTrigger(for animator: SidebarToggleAnimator) {
        guard SidebarNavigationTimings.isEnabled else { return }
        triggerTargets[ObjectIdentifier(animator)] = { [weak animator] in animator }
        guard !isTriggerRegistered else { return }
        isTriggerRegistered = true
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            { _, _, _, _, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        for target in SidebarToggleSlideProbe.triggerTargets.values {
                            if let animator = target() { SidebarToggleSlideProbe.toggleIfFrontmost(animator) }
                        }
                    }
                }
            },
            "com.cmuxterm.debug.sidebar-toggle" as CFString,
            nil,
            .deliverImmediately
        )
    }
}
#endif
