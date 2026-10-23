import CmuxNextActions
import Foundation

/// `diagnostics.viewHangReport` (palette, the Settings button, `cmux settings view-hang-report`):
/// the exact JSON of the last hang report sent, else a preview of what would be sent now, in a
/// cmux file tab of the run's pane (else the active window's focused pane).
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
    }
}
