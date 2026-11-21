import CmuxNextPages
import CmuxNextSettings
import Foundation

extension AgentPaneView {
    /// The pid a flicker line names for this pane's page: the WebKit WebContent process last seen at a
    /// finished load (the old host's, or the page host's ``PageWebView``), and 0 for a page that shows
    /// in Chromium, whose renderer pid the app does not know (the line then has no `pid`).
    var flickerPid: Int32 {
        guard let page else { return knownWebContentPid }
        return page.showsChromium ? 0 : page.knownWebContentPid
    }

    /// The page host's `diag.flicker` batch (``AgentPageProvider/onFlicker``) into the app's ring
    /// file, as ``AgentPaneBridge`` does for the old host: the line is built here and written on the
    /// log's utility queue.
    func recordPageFlicker(_ params: JSONValue) {
        let object = params.foundationObject as? [String: Any]
        forwardFocusLoss(object)
        guard let flickerLog else { return }
        flickerLog.recordPage(object, page: AgentPageFlickerLog.pageName(self), pid: flickerPid)
    }

    /// The batch's `focus-lost` events (focusLossWatch.ts: a text input of the page lost the
    /// keyboard with no key or click) to the app's focus log, as `key=value` words.
    func forwardFocusLoss(_ params: [String: Any]?) {
        guard let onPageFocusLost, let events = params?["events"] as? [Any] else { return }
        for case let event as [String: Any] in events where event["kind"] as? String == "focus-lost" {
            let words = event.filter { $0.key != "kind" && $0.key != "at" }.sorted { $0.key < $1.key }
                .map { "\($0.key)=\(String(describing: $0.value).prefix(32))" }
            onPageFocusLost(window, (["page=\(AgentPageFlickerLog.pageName(self))"] + words).joined(separator: " "))
        }
    }
}
