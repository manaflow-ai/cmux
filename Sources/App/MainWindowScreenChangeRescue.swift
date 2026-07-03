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
/// A dirty flag records signature changes seen mid-burst so a transient
/// disconnect-and-reconnect inside one debounce window still triggers a
/// rescue pass — but that settled-back pass runs at the constrain veto's own
/// thresholds, not the strict drag-band ones: docked Macs can re-enumerate
/// displays on every wake, and a wake flap must not disturb placements the
/// veto deliberately protects (e.g. a titlebar tucked under the menu bar).
@MainActor
final class MainWindowScreenChangeRescue {
    static let shared = MainWindowScreenChangeRescue()

    private var observer: NSObjectProtocol?
    private var cachedSignature: [MainWindowScreenRescueCore.TopologySignatureEntry] = []
    private var topologyDirty = false
    private var pendingRescue: Task<Void, Never>?
    private let debounceInterval: Duration = .milliseconds(400)

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
        pendingRescue = Task { [weak self, debounceInterval] in
            guard (try? await Task.sleep(for: debounceInterval)) != nil else { return }
            self?.performRescueIfNeeded()
        }
    }

    private func performRescueIfNeeded() {
        pendingRescue = nil
        let displays = Self.currentDisplays()
        // Mid-reconfiguration the screen list can be transiently empty; keep
        // the cache and dirty flag so the follow-up notification re-evaluates.
        guard !displays.isEmpty else { return }

        let signature = MainWindowScreenRescueCore.topologySignature(of: displays)
        let signatureDiffers = signature != cachedSignature
        let dirtyOnly = topologyDirty && !signatureDiffers
        cachedSignature = signature
        topologyDirty = false
        guard signatureDiffers || dirtyOnly else { return }

        // Settled arrangement change: the drag band must end up usably
        // visible (strict). Settled-back transient (wake flap, KVM bounce):
        // only rescue what the constrain veto itself would abandon, so
        // veto-protected placements never move on a flap.
        let thresholds: WindowTitlebarReachability.Thresholds =
            signatureDiffers ? .strict : .constrainVeto

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

    private static func currentTopologySignature() -> [MainWindowScreenRescueCore.TopologySignatureEntry] {
        MainWindowScreenRescueCore.topologySignature(of: currentDisplays())
    }

    private static func rectDescription(_ rect: CGRect) -> String {
        "\(Int(rect.minX.rounded())),\(Int(rect.minY.rounded())) " +
            "\(Int(rect.width.rounded()))x\(Int(rect.height.rounded()))"
    }
}
