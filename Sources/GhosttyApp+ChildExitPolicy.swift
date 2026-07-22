import CMUXDebugLog
import CmuxTerminal
import CmuxTerminalCore
import Foundation
import GhosttyKit

extension GhosttyApp {
    func handleChildExitedAction(
        runtimeSurface: TerminalSurface?,
        tabId: UUID?,
        surfaceId: UUID?,
        message: ghostty_surface_message_childexited_s
    ) -> Bool {
        let keepSurfaceVisible = TerminalChildExitPolicy(
            abnormalRuntimeMilliseconds: abnormalCommandExitRuntimeMilliseconds()
        ).shouldKeepSurfaceVisible(runtimeMilliseconds: message.timetime_ms)

#if DEBUG
        cmuxDebugLog(
            "surface.action.showChildExited tab=\(tabId?.uuidString.prefix(5) ?? "nil") " +
            "surface=\(surfaceId?.uuidString.prefix(5) ?? "nil") " +
            "runtimeMs=\(message.timetime_ms) keepVisible=\(keepSurfaceVisible ? 1 : 0)"
        )
        TerminalChildExitProbe().write(
            [
                "probeShowChildExitedTabId": tabId?.uuidString ?? "",
                "probeShowChildExitedSurfaceId": surfaceId?.uuidString ?? "",
                "probeShowChildExitedRuntimeMs": String(message.timetime_ms),
                "probeShowChildExitedKeptVisible": keepSurfaceVisible ? "1" : "0",
            ],
            increments: ["probeShowChildExitedCount": 1]
        )
#endif

        if let runtimeSurface {
            // Avoid re-entrant close/deinit while Ghostty dispatches this callback.
            DispatchQueue.main.async {
                guard let app = AppDelegate.shared else { return }
                guard GhosttyApp.terminalSurfaceRegistry.surface(id: runtimeSurface.id) === runtimeSurface else { return }
                if !keepSurfaceVisible,
                   let surfaceId,
                   app.closeWindowDockRuntimeSurface(surfaceId: surfaceId, force: true) {
                    return
                }
                if let tabId, let surfaceId,
                   let manager = app.tabManagerFor(tabId: tabId) ?? app.tabManager {
                    manager.closePanelAfterChildExited(
                        tabId: tabId,
                        surfaceId: surfaceId,
                        runtimeSurface: runtimeSurface,
                        keepSurfaceVisible: keepSurfaceVisible
                    )
                }
            }
        }

        // Returning false lets Ghostty render its detailed abnormal-exit text
        // and, by Ghostty's contract, retain the dead surface for inspection.
        return !keepSurfaceVisible
    }

    private func abnormalCommandExitRuntimeMilliseconds() -> UInt32 {
        let defaultValue: UInt32 = 250
        guard let config else { return defaultValue }
        var value = defaultValue
        let key = "abnormal-command-exit-runtime"
        guard ghostty_config_get(
            config,
            &value,
            key,
            UInt(key.lengthOfBytes(using: .utf8))
        ) else {
            return defaultValue
        }
        return value
    }
}
