import CmuxNextActions
import Foundation

/// `diagnostics.viewHangReport` (palette, the Settings button, `cmux settings view-hang-report`):
/// the exact JSON of the last hang report sent, else a preview of what would be sent now, in a
/// cmux file tab of the run's pane (else the active window's focused pane). Hidden in a build without hang reports.
enum HangReportsHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.addSettingOffReason(["diagnostics.viewHangReport"]) { AppProcessRoot.shared.hangReports?.isAvailable == true ? nil : HangReportsStrings.unavailable }
        registry.bind("diagnostics.viewHangReport", run: { invocation in
            guard let controller = AppProcessRoot.shared.hangReports else { return }
            let pane = invocation.target == nil ? context.services.windows.active?.focusedPane : context.paneController(invocation)
            controller.viewReport { [weak viewers = context.services.viewers] url in
                _ = viewers?.openFile(url, in: pane, markdown: false)
            }
        })
    }
}
