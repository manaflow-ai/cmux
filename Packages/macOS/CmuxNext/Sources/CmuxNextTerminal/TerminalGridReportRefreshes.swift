import AppKit
import CmuxNextWakeups

/// One per window: the display refreshes that end its terminals' grid-report windows (``TerminalGridReportTicks``,
/// RESIZE P0 6). Its frame client runs only while a window is open: each refresh ticks every coalescer that waits, and a
/// refresh that finds none waiting stops it.
@MainActor
final class TerminalGridReportRefreshes: TerminalGridReportTicks {
    private struct Waiting {
        weak var coalescer: TerminalGridReportCoalescer?
    }

    private weak var window: NSWindow?
    private var waiting: [ObjectIdentifier: Waiting] = [:]
    private lazy var client = FrameClient(owner: "Terminal.gridReportRefreshes", isAnimation: false, scheduler: { [weak self] in
        self?.window.map(FrameScheduler.forWindow) ?? .app
    }) { [weak self] _ in
        self?.tick() ?? false
    }

    private init(window: NSWindow) {
        self.window = window
    }

    private static var associationKey: UInt8 = 0

    /// `window`'s refreshes, made on first use and kept by the window.
    static func forWindow(_ window: NSWindow) -> TerminalGridReportRefreshes {
        if let refreshes = objc_getAssociatedObject(window, &associationKey) as? TerminalGridReportRefreshes { return refreshes }
        let refreshes = TerminalGridReportRefreshes(window: window)
        objc_setAssociatedObject(window, &associationKey, refreshes, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return refreshes
    }

    /// `coalescer`'s window ends at the next refresh (RESIZE P0 6); it is ticked each refresh until a refresh finds
    /// nothing waiting, which also clears the refresh its last send spent (RESIZE P0 7).
    func tickGridReports(_ coalescer: TerminalGridReportCoalescer) {
        waiting[ObjectIdentifier(coalescer)] = Waiting(coalescer: coalescer)
        client.activate()
    }

    /// One refresh: each waiting window ends (its newest grid goes; its timer is the backstop).
    private func tick() -> Bool {
        for (id, entry) in waiting where entry.coalescer?.frameTicked() != true {
            waiting[id] = nil
        }
        return !waiting.isEmpty
    }
}
