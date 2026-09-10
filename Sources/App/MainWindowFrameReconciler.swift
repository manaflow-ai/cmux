import AppKit
import CmuxWindowing

/// Repairs main-window geometry after AppKit or the display system changes it.
/// Display changes, activation, and restoration share one policy: recover
/// ordinary and zoomed windows, with full-width fullscreen repairs limited to
/// guarded display-topology changes. Split View tiles remain owned by AppKit.
@MainActor
final class MainWindowFrameReconciler {
    private let fitCore: MainWindowVisibleFrameFitCore

    /// Describes the lifecycle event that requested a frame repair.
    enum Trigger {
        /// A changed topology permits ordinary and full-width fullscreen repair.
        case displayTopology(changed: Bool)
        case applicationActivation
        case restorationCheckpoint

        var repairsOrdinaryWindows: Bool {
            switch self {
            case .displayTopology(let topologyChanged):
                return topologyChanged
            case .restorationCheckpoint:
                return true
            case .applicationActivation:
                return false
            }
        }

        var repairsFullscreenWindows: Bool {
            if case .displayTopology(let topologyChanged) = self {
                return topologyChanged
            }
            return false
        }
    }

    init(fitCore: MainWindowVisibleFrameFitCore = MainWindowVisibleFrameFitCore()) {
        self.fitCore = fitCore
    }

    /// Reports whether every requested frame was accepted by AppKit.
    @discardableResult
    func repair(
        displays: [SessionDisplayGeometry],
        windows: [NSWindow],
        trigger: Trigger
    ) -> Bool {
        guard !displays.isEmpty else { return false }

        let mainWindows = windows.compactMap { $0 as? CmuxMainWindow }
        guard !mainWindows.isEmpty else { return true }

        var fitCompleted = true
        for window in mainWindows {
            let mode: MainWindowFrameFitMode?
            if window.styleMask.contains(.fullScreen) {
                // Split View also sets this style. Only the topology path may
                // repair full-width frames; partial-width tiles stay untouched.
                mode = trigger.repairsFullscreenWindows
                    ? .nativeFullscreenTopologyChange
                    : .nativeFullscreen
            } else if window.cmuxWantsZoomedFrame {
                mode = .zoomed
            } else if trigger.repairsOrdinaryWindows {
                mode = .visibleFrame
            } else {
                mode = nil
            }

            guard let mode,
                  let targetFrame = fitCore.repairedFrame(
                      for: window.frame,
                      displays: displays,
                      minimumWidth: CGFloat(SessionPersistencePolicy.minimumWindowWidth),
                      minimumHeight: CGFloat(SessionPersistencePolicy.minimumWindowHeight),
                      mode: mode
                  ) else {
                continue
            }
            guard targetFrame != window.frame else { continue }
            let originalFrame = window.frame
#if DEBUG
            cmuxDebugLog(
                "mainWindow.frameRepair.clamp win=\(window.windowNumber) " +
                    "from={\(Self.rectDescription(originalFrame))} to={\(Self.rectDescription(targetFrame))}"
            )
#endif
            sentryBreadcrumb(
                "mainWindow.frameRepair.clamp",
                category: "window",
                data: [
                    "from": Self.rectDescription(originalFrame),
                    "to": Self.rectDescription(targetFrame),
                ]
            )
            window.setFrameForManagedPlacement(targetFrame, display: true)
            if window.frame != targetFrame {
                fitCompleted = false
            }
        }
        return fitCompleted
    }

    private static func rectDescription(_ rect: CGRect) -> String {
        "\(Int(rect.minX.rounded())),\(Int(rect.minY.rounded())) " +
            "\(Int(rect.width.rounded()))x\(Int(rect.height.rounded()))"
    }
}
