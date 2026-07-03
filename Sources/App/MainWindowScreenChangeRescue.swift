import AppKit
import CmuxWindowing

/// Watches for real display-topology changes and re-clamps any main window
/// whose drag handle became unreachable. This is the active half of the
/// stranded-window fix: `CmuxMainWindow.constrainFrameRect` stops vetoing
/// AppKit's rescue for stranded frames, and this controller handles the
/// disconnects where AppKit never re-constrains cmux's windows at all.
/// Decision logic lives in `MainWindowScreenRescueCore` (pure, tested); this
/// class is the thin AppKit shell.
///
/// The topology-signature gate is load-bearing, not an optimization: sleep and
/// wake fire the same `didChangeScreenParametersNotification` with an
/// unchanged signature, and must never move a window (that regression class is
/// the anti-creep behavior pinned by `CmuxMainWindowConstrainFrameTests`).
/// A dirty flag records signature changes seen before the coalesced idle pass
/// so a transient disconnect-and-reconnect inside one notification burst still
/// triggers a rescue pass — but that settled-back pass runs at the constrain
/// veto's own thresholds, not the strict drag-band ones: docked Macs can
/// re-enumerate displays on every wake, and a wake flap must not disturb
/// placements the veto deliberately protects (e.g. a titlebar tucked under the
/// menu bar).
@MainActor
final class MainWindowScreenChangeRescue {
    private var screenParametersObserver: NSObjectProtocol?
    private var coalescedRescueObserver: NSObjectProtocol?
    private var cachedSignature: [MainWindowDisplayTopologySignatureEntry] = []
    private var topologyDirty = false
    private let coalescedRescueNotification = Notification.Name("cmux.mainWindowScreenChangeRescue.perform")
    private let rescueCore: MainWindowScreenRescueCore

    /// Owned and installed by `AppDelegate`.
    init(
        rescueCore: MainWindowScreenRescueCore = MainWindowScreenRescueCore()
    ) {
        self.rescueCore = rescueCore
    }

    func install() {
        guard screenParametersObserver == nil else { return }
        // Seed the cache so the first notification after launch is compared
        // against the launch topology instead of reading as a change.
        cachedSignature = currentTopologySignature()
        coalescedRescueObserver = NotificationCenter.default.addObserver(
            forName: coalescedRescueNotification,
            object: self,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.performRescueIfNeeded()
            }
        }
        screenParametersObserver = NotificationCenter.default.addObserver(
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
        // once, when the main run loop reaches idle after the burst.
        if currentTopologySignature() != cachedSignature {
            topologyDirty = true
        }
        NotificationQueue.default.enqueue(
            Notification(name: coalescedRescueNotification, object: self),
            postingStyle: .whenIdle,
            coalesceMask: [.onName, .onSender],
            forModes: nil
        )
    }

    private func performRescueIfNeeded() {
        let displays = Self.currentDisplays()
        // Mid-reconfiguration the screen list can be transiently empty; keep
        // the cache and dirty flag so the follow-up notification re-evaluates.
        guard !displays.isEmpty else { return }

        let signature = rescueCore.topologySignature(of: displays)
        let arrangementDiffers = !rescueCore.signaturesHaveSameArrangement(signature, cachedSignature)
        let reachabilityBoundsDiffer = signature != cachedSignature
        let dirtyOnly = topologyDirty && !arrangementDiffers
        cachedSignature = signature
        topologyDirty = false
        guard arrangementDiffers || dirtyOnly || reachabilityBoundsDiffer else { return }

        // Settled arrangement change: the drag band must end up usably
        // visible (strict). Settled-back transient (wake flap, KVM bounce), or
        // a visible-frame-only change such as a side/bottom Dock move: only
        // rescue what the constrain veto itself would abandon, so
        // veto-protected placements never move on those flaps.
        let thresholds: WindowTitlebarReachabilityThresholds
        if arrangementDiffers {
            thresholds = .strictRescue
        } else {
            thresholds = .constrainVeto
        }

        // All live main terminal windows, including miniaturized (the frame is
        // the deminiaturize target), app-hidden, and soft-hidden ones (they
        // re-show later and would re-strand). Fullscreen windows are skipped:
        // Spaces migrates them itself and clamping would fight the transition.
        let windows = NSApp.windows
            .compactMap { $0 as? CmuxMainWindow }
            .filter { window in
                !window.styleMask.contains(.fullScreen)
            }
        guard !windows.isEmpty else { return }

        let rescued = rescueCore.rescuedFrames(
            for: windows.map(\.frame),
            displays: displays,
            thresholds: thresholds,
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

    private func currentTopologySignature() -> [MainWindowDisplayTopologySignatureEntry] {
        rescueCore.topologySignature(of: Self.currentDisplays())
    }

    private static func rectDescription(_ rect: CGRect) -> String {
        "\(Int(rect.minX.rounded())),\(Int(rect.minY.rounded())) " +
            "\(Int(rect.width.rounded()))x\(Int(rect.height.rounded()))"
    }
}
