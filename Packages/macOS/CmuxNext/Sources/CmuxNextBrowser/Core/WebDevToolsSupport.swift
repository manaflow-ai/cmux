import Foundation

/// Whether an engine can run one ``WebDevToolsCommand`` on its page.
public nonisolated enum WebDevToolsSupport: Hashable, Sendable {
    /// The engine runs the command.
    case supported
    /// The engine cannot run it; the palette shows the row disabled with
    /// ``WebDevToolsLimit/message``.
    case limited(WebDevToolsLimit)

    /// The limit, or nil when supported.
    public var limit: WebDevToolsLimit? {
        if case .limited(let limit) = self { return limit }
        return nil
    }
}

/// Why an engine cannot run a developer-tools command, as the disabled
/// palette row says it.
public nonisolated enum WebDevToolsLimit: String, CaseIterable, Hashable, Sendable {
    /// No web view (browser tab, Markdown, agent chat, page) has focus.
    case noWebView
    /// Web Inspector has no host command for this tab.
    case webKitNoPanelCommand
    /// Only Chromium's DevTools protocol can do it.
    case chromiumOnly
    /// Web Inspector picks its own dock side.
    case webKitDockSide
    /// Chromium starts a recording only from the Performance panel.
    case useRecordButton
    /// Chromium takes heap snapshots only from the Memory panel.
    case useHeapSnapshotButton
    /// Web Inspector records memory in its Timelines tab.
    case webKitUseTimelines
    /// Chromium captures one node from the Elements panel's node menu.
    case useNodeMenu
    /// Web Inspector captures one node from the Elements tab's node menu.
    case webKitUseNodeMenu
    /// The console log is saved from the Console's own menu.
    case useConsoleSaveAs
    /// The command needs a browser tab, not another web view.
    case browserTabOnly

    /// The localized reason.
    public var message: String {
        switch self {
        case .noWebView:
            t("devtools.limit.noWebView", "Click in a browser tab or another web view first.")
        case .webKitNoPanelCommand:
            t("devtools.limit.webKitNoPanelCommand", "WebKit cannot open this tab directly. Open the Web Inspector and click the tab.")
        case .chromiumOnly:
            t("devtools.limit.chromiumOnly", "Chromium only. Use Open in Chromium for this page.")
        case .webKitDockSide:
            t("devtools.limit.webKitDockSide", "The Web Inspector sets its own side. Use its dock buttons.")
        case .useRecordButton:
            t("devtools.limit.useRecordButton", "Open the Performance panel and click Record.")
        case .useHeapSnapshotButton:
            t("devtools.limit.useHeapSnapshotButton", "Open the Memory panel and click Take snapshot.")
        case .webKitUseTimelines:
            t("devtools.limit.webKitUseTimelines", "Record memory in the Web Inspector's Timelines tab.")
        case .useNodeMenu:
            t("devtools.limit.useNodeMenu", "In Elements, right-click a node and choose Capture node screenshot.")
        case .webKitUseNodeMenu:
            t("devtools.limit.webKitUseNodeMenu", "In the Web Inspector, right-click a node and choose Capture Screenshot.")
        case .useConsoleSaveAs:
            t("devtools.limit.useConsoleSaveAs", "Right-click in the Console and choose Save as.")
        case .browserTabOnly:
            t("devtools.limit.browserTabOnly", "Works in browser tabs only.")
        }
    }

    private func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "DevTools", bundle: .module)
    }
}
