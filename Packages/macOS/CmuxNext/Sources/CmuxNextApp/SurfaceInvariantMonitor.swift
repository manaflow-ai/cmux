import os

/// Checks, once layout and presentation settle after a change, that every
/// visible pane's selected tab shows an installed, drawing surface with a
/// non-zero grid (no blank panes). A violation is logged (a fault in debug
/// builds) and counted for `debug.surfaces`; nothing is repaired here, so a
/// lifecycle bug stays visible instead of being papered over.
///
/// Event-driven: runs only for `settleFrames` display frames after a
/// presentation change, so an idle app keeps no display link.
@MainActor
final class SurfaceInvariantMonitor {
    /// Frames to wait after the last change (layout springs settle in ~250 ms).
    static let settleFrames = 30
    weak var services: AppServices?
    private let frames = FrameBatcher(owner: "SurfaceInvariantMonitor")
    private var remaining = 0
    private(set) var violations = 0
    private(set) var checks = 0
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.surfaces")

    /// A pane showed, hid, moved or released content.
    func noteChange() {
        let idle = remaining == 0
        remaining = Self.settleFrames
        if idle { scheduleStep() }
    }

    private func scheduleStep() {
        frames.scheduleFrame { [weak self] in self?.step() }
    }

    private func step() {
        remaining -= 1
        guard remaining <= 0 else { return scheduleStep() }
        remaining = 0
        check()
    }

    /// Blank panes right now. Public for `debug.surfaces`.
    func check() {
        guard let services else { return }
        checks += 1
        for row in SurfaceDiagnosticsReport.statuses(services) where row.status.isBlank {
            violations += 1
            let status = row.status
            let surface = status.terminal.map { "\($0)" } ?? "none"
            #if DEBUG
            logger.fault("blank pane \(status.paneKey, privacy: .public) selected=\(status.selectedTab ?? "-", privacy: .public) shown=\(status.shownTab ?? "-", privacy: .public) installed=\(status.contentInstalled) surface=\(surface, privacy: .public)")
            #else
            logger.error("blank pane \(status.paneKey, privacy: .public) selected=\(status.selectedTab ?? "-", privacy: .public)")
            #endif
        }
    }
}
