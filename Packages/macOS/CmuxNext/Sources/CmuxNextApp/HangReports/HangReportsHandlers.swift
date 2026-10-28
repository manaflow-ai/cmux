import CmuxNextActions
import CmuxNextBrowser
import CmuxNextControl
import CmuxNextFeatures
import CmuxNextWakeups
import Foundation

/// `diagnostics.viewHangReport` (palette, the Settings button, `cmux settings view-hang-report`):
/// the exact JSON of the last hang report sent, else a preview of what would be sent now, in a
/// cmux file tab of the run's pane (else the active window's focused pane).
/// `diagnostics.viewMetrics` (palette; feature `metricsView`, p09-observability task 065): every
/// field histogram since launch (``MetricsSnapshot``, chrome://histograms) written to
/// `Metrics/metrics.json` in the build's folder on the files lane, in a code editor tab that opens in
/// the run's turn and loads the file once it is written.
enum HangReportsHandlers {
    /// `writeMetrics` writes the metrics JSON to a file (blocking: it runs on the files lane); tests make it fail.
    /// `metricsFolder` replaces the build's folder (tests write to a temporary one).
    static func bind(into registry: ActionRegistry, context: AppActionContext, metricsFolder: URL? = nil,
                     writeMetrics: @escaping @Sendable (URL) throws -> Void = { try MetricsSnapshot().blockingWrite(to: $0) }) {
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
            let target = invocation.target == nil ? services.windows.active?.focusedPane : context.paneController(invocation)
            guard let pane = target ?? services.windows.active?.focusedPane else { return .refused(FilePageStrings.noPane) }
            // The folder (which exists) resolved, so the path is the same before and after the write: the tab
            // keys its file by it (`/var` and `/private/var` are one tab, a second run selects it).
            let folder = (metricsFolder ?? SidebarSnapshotFile.buildDirectory(launch: launch)).standardizedFileURL.resolvingSymlinksInPath()
            let file = folder.appending(path: "Metrics/metrics.json")
            // The viewer tab opens in this turn, its page loading until the file is written; a failed
            // write fails the page (its Retry reads again) and the registry's notice names the reason.
            let written = OneShot<String?>()
            services.viewers.editorPages.open(file, in: pane, focus: true, ready: {
                // Only a closed tab's read is cancelled, so the cancel's reason is never shown.
                // concurrency-allow: OneShot.wait is an async suspension (a continuation the write resolves), not a blocking wait
                await written.wait(cancelled: "cancelled")
            })
            let work = services.work, write = writeMetrics
            return .applied(ActionConfirmation(send: {
                do {
                    // The counters are read and the JSON written off the main thread.
                    try await work.run(.userBlocking, mayBlock: .files) { try write(file) }
                    written.resolve(nil)
                    return nil
                } catch {
                    written.resolve(error.localizedDescription)
                    return ActionWorkFailure(error.localizedDescription)
                }
            }))
        })
    }
}
