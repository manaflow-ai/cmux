import AppKit
import CmuxNextCompat
import os
import CmuxNextWakeups

/// Checks, once layout and presentation settle after a change, that every
/// visible pane's selected tab shows an installed, drawing surface with a
/// non-zero grid (no blank panes). A violation is logged (a fault in debug
/// builds) and counted for `debug.surfaces`; nothing is repaired here, so a
/// lifecycle bug stays visible instead of being papered over.
///
/// Event-driven: one deadline `settleDelay` after the last presentation change
/// (no display link). A window's occlusion change is such a change: panes in an
/// occluded window are not judged (they draw nothing by design), so the check
/// after the window is visible again proves every surface drew. It hears every
/// window's AppKit notice through ``WindowOcclusionFamily`` (a page's child window
/// has no family) and, as a diagnostics-stage subscriber, each cover flip of the
/// windows it judges, after their content paused or drew again. It walks every
/// pane, so it runs by itself only in debug builds (no release scan per switch);
/// `debug.surfaces` reports blank panes on demand in any build.
@MainActor
final class SurfaceInvariantMonitor {
    /// Time after the last change before the check (layout springs settle in ~250 ms).
    static let settleDelay: Duration = .milliseconds(500)
    weak var services: AppServices?
    /// The check's deadline on the app's scheduler, made at the first change: `background` work, nobody waits on it.
    private var settle: MainDeadline?
    private(set) var violations = 0
    private(set) var checks = 0
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.surfaces")
    private var occlusionObservation: MainActorObservation?
    /// Its diagnostics-stage subscriptions to the families of the windows it judges.
    private var familyWatches: [FamilyWatch] = []
    /// Tab switch timeline marks (category "tab-switch", debug level).
    nonisolated static let tabSwitchLog = Logger(subsystem: "com.cmuxterm.app.next", category: "tab-switch")

    /// Re-checks after any window's occlusion changes (AppServices wiring).
    func observeWindowOcclusion(center: NotificationCenter = .default) {
        guard occlusionObservation == nil else { return }
        occlusionObservation = WindowOcclusionFamily.observeSystemChanges(center: center) { [weak self] window in
            // In the notice's own turn: noteChange only arms the settle deadline.
            self?.noteChange()
            self?.followFamilies()
            // Tab switch timeline (cx-asb1): when a page child window's occlusion state lands.
            let child = window.parent != nil
            let visible = WindowOcclusionFamily.isOnScreen(window)
            // wall-clock: one timeline with the Control and Browser tab-switch marks and the page's performance.timeOrigin
            Self.tabSwitchLog.debug("tab-switch occlusion-\(child ? "child" : "top", privacy: .public)-\(visible ? "visible" : "hidden", privacy: .public)-\(String(describing: type(of: window)).filter(\.isLetter), privacy: .public)\(window.identifier?.rawValue.filter(\.isLetter) ?? "", privacy: .public) \(Date().timeIntervalSince1970 * 1_000, format: .fixed(precision: 3), privacy: .public)")
        }
    }

    /// Hears the cover flips of the windows it judges (an opaque cmux window over one posts no AppKit
    /// notice). A window joins at its first AppKit notice, which ordering it in posts.
    private func followFamilies() {
        familyWatches.removeAll { $0.window == nil }
        for window in services?.windows.controllers.compactMap(\.window) ?? []
        where !familyWatches.contains(where: { $0.window === window }) {
            let subscription = WindowOcclusionFamily.of(window).subscribe(.diagnostics, owner: "SurfaceInvariantMonitor") { [weak self] _ in
                self?.noteChange()
            }
            familyWatches.append(FamilyWatch(window: window, subscription: subscription))
        }
    }

    private struct FamilyWatch {
        weak var window: NSWindow?
        let subscription: WindowOcclusionSubscription
    }

    /// A pane showed, hid, moved or released content.
    func noteChange() {
        #if DEBUG
        guard let services else { return }
        let settle = self.settle ?? MainDeadline(owner: "SurfaceInvariantMonitor.settle", workClass: .background, scheduler: services.mainDeadlines)
        self.settle = settle
        settle.schedule(after: Self.settleDelay) { [weak self] in self?.check() }
        #endif
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
