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
        guard let flickerLog else { return }
        flickerLog.recordPage(params.foundationObject as? [String: Any], page: AgentPageFlickerLog.pageName(self), pid: flickerPid)
    }
}
