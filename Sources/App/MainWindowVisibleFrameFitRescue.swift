import AppKit
import CmuxWindowing

/// Watches real display-topology changes and fits cut-off main windows back
/// into a current visible frame. This complements the titlebar-stranding rescue
/// in PR #7265: that pass handles unreachable drag handles; this pass handles
/// reachable windows whose body is still clipped or oversized.
@MainActor
final class MainWindowVisibleFrameFitRescue: NSObject {
    private let coalescedFitNotification = Notification.Name("cmux.mainWindowVisibleFrameFitRescue.perform")
    private let fitCore: MainWindowVisibleFrameFitCore
    private var cachedSignature: [MainWindowVisibleFrameTopologySignatureEntry] = []
    private var isInstalled = false

    /// Owned and installed by `AppDelegate`.
    init(fitCore: MainWindowVisibleFrameFitCore = MainWindowVisibleFrameFitCore()) {
        self.fitCore = fitCore
        super.init()
    }

    func install() {
        guard !isInstalled else { return }
        cachedSignature = currentTopologySignature()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(performFitIfNeeded(_:)),
            name: coalescedFitNotification,
            object: self
        )
        isInstalled = true
    }

    @objc private func screenParametersDidChange(_: Notification) {
        NotificationQueue.default.enqueue(
            Notification(name: coalescedFitNotification, object: self),
            postingStyle: .whenIdle,
            coalesceMask: [.onName, .onSender],
            forModes: nil
        )
    }

    @objc private func performFitIfNeeded(_: Notification) {
        let displays = Self.currentDisplays()
        guard !displays.isEmpty else { return }

        let signature = fitCore.topologySignature(of: displays)
        let topologyChanged = signature != cachedSignature
        cachedSignature = signature
        guard topologyChanged else { return }

        let windows = NSApp.windows
            .compactMap { $0 as? CmuxMainWindow }
            .filter { window in
                !window.styleMask.contains(.fullScreen)
            }
        guard !windows.isEmpty else { return }

        let fittedFrames = fitCore.fittedFrames(
            for: windows.map(\.frame),
            displays: displays,
            minimumWidth: CGFloat(SessionPersistencePolicy.minimumWindowWidth),
            minimumHeight: CGFloat(SessionPersistencePolicy.minimumWindowHeight)
        )
        for (window, targetFrame) in zip(windows, fittedFrames) {
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

    private func currentTopologySignature() -> [MainWindowVisibleFrameTopologySignatureEntry] {
        fitCore.topologySignature(of: Self.currentDisplays())
    }

    private static func rectDescription(_ rect: CGRect) -> String {
        "\(Int(rect.minX.rounded())),\(Int(rect.minY.rounded())) " +
            "\(Int(rect.width.rounded()))x\(Int(rect.height.rounded()))"
    }
}
