import AppKit
import CmuxWindowing

/// Decision core for rescuing main windows stranded by a display-topology
/// change (monitor unplug, clamshell close). Pure and `nonisolated` so the
/// behavior is testable deterministically on CI regardless of the host's
/// display configuration; `MainWindowScreenChangeRescue` below is the live
/// observer shell.
enum MainWindowScreenRescueCore {
    /// One display's identity and full frame. `visibleFrame` is deliberately
    /// omitted: Dock/menu-bar resizes change only the visible frame and can
    /// never strand a titlebar, so they must not read as topology changes.
    struct TopologySignatureEntry: Equatable {
        let displayID: UInt32?
        let frame: CGRect
    }

    /// Order-independent signature of the current display topology. Two
    /// signatures compare equal exactly when the same displays sit at the same
    /// frames — the gate that keeps sleep/wake (same topology, same
    /// notification) from ever triggering a rescue.
    nonisolated static func topologySignature(
        of displays: [SessionDisplayGeometry]
    ) -> [TopologySignatureEntry] {
        displays
            .map { TopologySignatureEntry(displayID: $0.displayID, frame: $0.frame) }
            .sorted { lhs, rhs in
                if lhs.frame.minX != rhs.frame.minX { return lhs.frame.minX < rhs.frame.minX }
                if lhs.frame.minY != rhs.frame.minY { return lhs.frame.minY < rhs.frame.minY }
                return (lhs.displayID ?? .max) < (rhs.displayID ?? .max)
            }
    }

    /// For each window frame, the frame the window should move to so its drag
    /// band becomes reachable, or nil when the window must not move (drag band
    /// already reachable per the strict thresholds, or no displays available).
    ///
    /// Placement reuses the session-restore geometry: pick the display with the
    /// greatest body overlap (else the nearest by center distance), then clamp
    /// into its visible frame with the same floors session restore applies.
    nonisolated static func rescuedFrames(
        for windowFrames: [CGRect],
        displays: [SessionDisplayGeometry],
        minimumWidth: CGFloat,
        minimumHeight: CGFloat
    ) -> [CGRect?] {
        guard !displays.isEmpty else { return windowFrames.map { _ in nil } }
        let visibleFrames = displays.map(\.visibleFrame)
        return windowFrames.map { frame in
            if WindowTitlebarReachability.isTopStripReachable(
                frame,
                onAnyOf: visibleFrames,
                thresholds: .strict
            ) {
                return nil
            }
            let target = targetDisplay(for: frame, in: displays) ?? displays[0]
            return AppDelegate.clampFrame(
                frame,
                within: target.visibleFrame,
                minWidth: minimumWidth,
                minHeight: minimumHeight
            )
        }
    }

    /// Greatest body-overlap display, else nearest by center distance —
    /// mirroring `AppDelegate.display(for:in:)`'s selection order.
    private nonisolated static func targetDisplay(
        for frame: CGRect,
        in displays: [SessionDisplayGeometry]
    ) -> SessionDisplayGeometry? {
        let overlaps = displays.map { display in
            (display: display, area: AppDelegate.intersectionArea(frame, display.visibleFrame))
        }
        if let best = overlaps.max(by: { $0.area < $1.area }), best.area > 0 {
            return best.display
        }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return displays.min { lhs, rhs in
            AppDelegate.distanceSquared(lhs.visibleFrame, center)
                < AppDelegate.distanceSquared(rhs.visibleFrame, center)
        }
    }
}

/// Watches for real display-topology changes and re-clamps any main window
/// whose drag handle became unreachable. This is the active half of the
/// stranded-window fix: `CmuxMainWindow.constrainFrameRect` stops vetoing
/// AppKit's rescue for stranded frames, and this controller handles the
/// disconnects where AppKit never re-constrains cmux's windows at all.
///
/// The topology-signature gate is load-bearing, not an optimization: sleep and
/// wake fire the same `didChangeScreenParametersNotification` with an
/// unchanged signature, and must never move a window (that regression class is
/// the anti-creep behavior pinned by `CmuxMainWindowConstrainFrameTests`).
/// A dirty flag records signature changes seen mid-burst so a transient
/// disconnect-and-reconnect inside one debounce window still triggers a
/// rescue pass for windows macOS stranded during the transient.
@MainActor
final class MainWindowScreenChangeRescue {
    static let shared = MainWindowScreenChangeRescue()

    private var observer: NSObjectProtocol?
    private var cachedSignature: [MainWindowScreenRescueCore.TopologySignatureEntry] = []
    private var topologyDirty = false
    private var pendingRescue: DispatchWorkItem?
    private let debounceInterval: TimeInterval = 0.4

    private init() {}

    func install() {
        guard observer == nil else { return }
        // Seed the cache so the first notification after launch is compared
        // against the launch topology instead of reading as a change.
        cachedSignature = Self.currentTopologySignature()
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.screenParametersDidChange()
            }
        }
    }

    private func screenParametersDidChange() {
        // Reconfigurations fire this notification 2-4 times; compare eagerly
        // (so a transient A->B->A still marks the burst dirty) but act only
        // once, after the burst settles.
        if Self.currentTopologySignature() != cachedSignature {
            topologyDirty = true
        }
        pendingRescue?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.performRescueIfNeeded()
            }
        }
        pendingRescue = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    private func performRescueIfNeeded() {
        pendingRescue = nil
        let displays = Self.currentDisplays()
        // Mid-reconfiguration the screen list can be transiently empty; keep
        // the cache and dirty flag so the follow-up notification re-evaluates.
        guard !displays.isEmpty else { return }

        let signature = MainWindowScreenRescueCore.topologySignature(of: displays)
        let topologyChanged = topologyDirty || signature != cachedSignature
        cachedSignature = signature
        topologyDirty = false
        guard topologyChanged else { return }

        // All main terminal windows, including miniaturized (the frame is the
        // deminiaturize target) and soft-hidden ones (they re-show later and
        // would re-strand). Fullscreen windows are skipped: Spaces migrates
        // them itself and clamping would fight the transition.
        let windows = NSApp.windows
            .compactMap { $0 as? CmuxMainWindow }
            .filter { window in
                guard !window.styleMask.contains(.fullScreen) else { return false }
                return window.isVisible || window.isMiniaturized
            }
        guard !windows.isEmpty else { return }

        let rescued = MainWindowScreenRescueCore.rescuedFrames(
            for: windows.map(\.frame),
            displays: displays,
            minimumWidth: CGFloat(SessionPersistencePolicy.minimumWindowWidth),
            minimumHeight: CGFloat(SessionPersistencePolicy.minimumWindowHeight)
        )
        for (window, target) in zip(windows, rescued) {
            guard let target, target != window.frame else { continue }
            let from = window.frame
#if DEBUG
            cmuxDebugLog(
                "mainWindow.screenChange.clamp win=\(window.windowNumber) " +
                    "from={\(Self.rectDescription(from))} to={\(Self.rectDescription(target))}"
            )
#endif
            sentryBreadcrumb(
                "mainWindow.screenChange.clamp",
                category: "window",
                data: [
                    "from": Self.rectDescription(from),
                    "to": Self.rectDescription(target),
                ]
            )
            window.setFrame(target, display: true)
        }
    }

    private static func currentDisplays() -> [SessionDisplayGeometry] {
        NSScreen.screens.map { screen in
            SessionDisplayGeometry(
                displayID: screen.cmuxDisplayID,
                frame: screen.frame,
                visibleFrame: screen.visibleFrame
            )
        }
    }

    private static func currentTopologySignature() -> [MainWindowScreenRescueCore.TopologySignatureEntry] {
        MainWindowScreenRescueCore.topologySignature(of: currentDisplays())
    }

    private static func rectDescription(_ rect: CGRect) -> String {
        "\(Int(rect.minX.rounded())),\(Int(rect.minY.rounded())) " +
            "\(Int(rect.width.rounded()))x\(Int(rect.height.rounded()))"
    }
}
