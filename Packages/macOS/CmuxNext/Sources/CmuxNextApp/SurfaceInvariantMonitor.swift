import AppKit
import os
import CmuxNextLayout
import CmuxNextTerminal
import CmuxNextWakeups

/// Checks, once layout and presentation settle after a change, that every
/// visible pane's selected tab shows an installed, drawing surface with a
/// non-zero grid (no blank panes), one size per terminal (R3a) and no column a create
/// resized (R3b). A violation is logged (a fault in debug builds) and counted for
/// `debug.surfaces`; nothing is repaired here, so a bug stays visible.
///
/// Event-driven: one deadline `settleDelay` after the last presentation change
/// (no display link). A window's occlusion change is such a change: panes in an
/// occluded window are not judged (they draw nothing by design), so the check
/// after the window is visible again proves every surface drew. It walks every
/// pane, so it runs by itself only in debug builds (no release scan per switch);
/// `debug.surfaces` reports blank panes on demand in any build.
@MainActor
final class SurfaceInvariantMonitor {
    /// Time after the last change before the check (layout springs settle in ~250 ms).
    static let settleDelay: Duration = .milliseconds(500)
    weak var services: AppServices?
    private let settle = DemandTimer(owner: "SurfaceInvariantMonitor.settle")
    private var blankPanes = 0
    private let sizes = TerminalSizeInvariant(), columns = ColumnWidthInvariant()
    var violations: Int { blankPanes + sizes.violations + columns.violations }
    private(set) var checks = 0
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.surfaces")
    private var occlusionObserver: (any NSObjectProtocol)?
    /// Tab switch timeline marks (category "tab-switch", debug level).
    nonisolated static let tabSwitchLog = Logger(subsystem: "com.cmuxterm.app.next", category: "tab-switch")

    /// Re-checks after any window's occlusion changes (AppServices wiring).
    func observeWindowOcclusion() {
        guard occlusionObserver == nil else { return }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main
        ) { [weak self] note in
            // Tab switch timeline (cx-asb1): when a page child window's occlusion state lands.
            let window = note.object as? NSWindow
            MainActor.assumeIsolated { // main-proof: observer on queue: .main
                guard let window else { return }
                let child = window.parent != nil
                let visible = window.occlusionState.contains(.visible)
                Self.tabSwitchLog.debug("tab-switch occlusion-\(child ? "child" : "top", privacy: .public)-\(visible ? "visible" : "hidden", privacy: .public)-\(String(describing: type(of: window)).filter(\.isLetter), privacy: .public)\(window.identifier?.rawValue.filter(\.isLetter) ?? "", privacy: .public) \(Date().timeIntervalSince1970 * 1_000, format: .fixed(precision: 3), privacy: .public)")
            }
            // task-owner: one main-actor hop per occlusion change; noteChange only arms the settle frames.
            Task { @MainActor in self?.noteChange() }
        }
    }

    /// A pane showed, hid, moved or released content.
    func noteChange() {
        #if DEBUG
        settle.schedule(after: Self.settleDelay) { @MainActor [weak self] in self?.check() }
        #endif
    }

    /// Blank panes right now. Public for `debug.surfaces`.
    func check() {
        guard let services else { return }
        checks += 1
        for row in SurfaceDiagnosticsReport.statuses(services) where row.status.isBlank {
            blankPanes += 1
            let status = row.status
            let surface = status.terminal.map { "\($0)" } ?? "none"
            #if DEBUG
            logger.fault("blank pane \(status.paneKey, privacy: .public) selected=\(status.selectedTab ?? "-", privacy: .public) shown=\(status.shownTab ?? "-", privacy: .public) installed=\(status.contentInstalled) surface=\(surface, privacy: .public)")
            #else
            logger.error("blank pane \(status.paneKey, privacy: .public) selected=\(status.selectedTab ?? "-", privacy: .public)")
            #endif
        }
        #if DEBUG
        let action = services.actionBudget.recent(1).first.map { "\($0.id)" } ?? "none"
        sizes.check(services.cache.terminals.map { (key: $0.key, session: $0.value.session) }, action: action)
        columns.check(services.windows.controllers.compactMap { $0.content?.layoutView }, action: action)
        if sizes.wantsRecheck { noteChange() }
        #endif
    }
}
