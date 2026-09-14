import AppKit
import CmuxWindowing

/// Fits cut-off main windows back into current display geometry after AppDelegate
/// observes and guards a real display-topology change. This complements the
/// titlebar-stranding rescue in PR #7265: that pass handles unreachable drag
/// handles; this pass handles reachable windows whose body is still clipped or
/// oversized, including native-fullscreen frames restored by AppKit.
@MainActor
final class MainWindowVisibleFrameFitRescue {
    private let fitCore: MainWindowVisibleFrameFitCore

    /// Owned and invoked by `AppDelegate` from the guarded screen-change path.
    init(fitCore: MainWindowVisibleFrameFitCore = MainWindowVisibleFrameFitCore()) {
        self.fitCore = fitCore
    }

    /// Fits each main window and reports whether every requested frame applied.
    @discardableResult
    func performFitIfNeeded(
        displays: [SessionDisplayGeometry],
        windows: [NSWindow]
    ) -> Bool {
        guard !displays.isEmpty else { return false }

        let mainWindows = windows
            .compactMap { $0 as? CmuxMainWindow }
        guard !mainWindows.isEmpty else { return true }

        let fittedFrames = mainWindows.map { window -> CGRect? in
            if window.styleMask.contains(.fullScreen) {
                return fitCore.fittedFullscreenFrame(
                    for: window.frame,
                    displays: displays
                )
            }
            return fitCore.fittedFrame(
                for: window.frame,
                displays: displays,
                minimumWidth: CGFloat(SessionPersistencePolicy.minimumWindowWidth),
                minimumHeight: CGFloat(SessionPersistencePolicy.minimumWindowHeight)
            )
        }
        var fitCompleted = true
        for (window, targetFrame) in zip(mainWindows, fittedFrames) {
            guard let targetFrame, targetFrame != window.frame else { continue }
            let originalFrame = window.frame
#if DEBUG
            cmuxDebugLog(
                "mainWindow.visibleFrameFit.clamp win=\(window.windowNumber) " +
                    "from={\(Self.rectDescription(originalFrame))} to={\(Self.rectDescription(targetFrame))}"
            )
#endif
            sentryBreadcrumb(
                "mainWindow.visibleFrameFit.clamp",
                category: "window",
                data: [
                    "from": Self.rectDescription(originalFrame),
                    "to": Self.rectDescription(targetFrame),
                ]
            )
            window.setFrame(targetFrame, display: true)
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
