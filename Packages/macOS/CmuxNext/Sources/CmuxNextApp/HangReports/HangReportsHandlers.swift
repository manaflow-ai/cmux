import CmuxNextActions
import CmuxNextControl
import CmuxNextFeatures
import CmuxNextWakeups
import Foundation

/// `diagnostics.viewHangReport` (palette, the Settings button, `cmux settings view-hang-report`):
/// the exact JSON of the last hang report sent, else a preview of what would be sent now, in a
/// cmux file tab of the run's pane (else the active window's focused pane).
/// `diagnostics.viewMetrics` (palette; feature `metricsView`, p09-observability task 065): every
/// field histogram since launch (``MetricsSnapshot``, chrome://histograms) written to
/// `Metrics/metrics.json` in the build's folder on the files lane, then opened the same way.
enum HangReportsHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("diagnostics.viewHangReport", run: { invocation in
            guard let controller = AppProcessRoot.shared.hangReports, controller.isAvailable else {
                throw ActionFailure(message: HangReportsStrings.unavailable)
            }
            let pane = invocation.target == nil ? context.services.windows.active?.focusedPane : context.paneController(invocation)
            controller.viewReport { [weak viewers = context.services.viewers] url in
                _ = viewers?.openFile(url, in: pane, markdown: false)
            }
        })
        let services = context.services, metricsOn = services.features.isEnabled(.metricsView), launch = services.environment.launch
        registry.bindEffect("diagnostics.viewMetrics", unavailable: { metricsOn ? nil : MetricsSnapshot.featureOffReason }, effect: { invocation in
            let pane = invocation.target == nil ? services.windows.active?.focusedPane : context.paneController(invocation)
            let work = services.work
            // action-wait-allow: the counters are read and the JSON is written off the main thread; the tab opens once the file exists.
            return .waiting(.fileSystem) { [weak viewers = services.viewers] in
                do {
                    let file = try await work.run(.userBlocking, mayBlock: .files) {
                        let file = SidebarSnapshotFile.buildDirectory(launch: launch).appending(path: "Metrics/metrics.json")
                        try MetricsSnapshot().blockingWrite(to: file)
                        return file
                    }
                    _ = viewers?.openFile(file, in: pane, markdown: false)
                    return nil
                } catch {
                    return ActionWorkFailure(error.localizedDescription)
                }
            }
        })
    }
}
