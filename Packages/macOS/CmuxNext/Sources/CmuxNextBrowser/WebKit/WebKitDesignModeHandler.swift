import CmuxNextCompat
import Foundation
import WebKit

/// Design mode's messages in a WebKit page (`BrowserDesignModeScript`): the handler lives only in
/// cmux's isolated world (`.defaultClient`, where `.isolated` scripts run), top frame only, so a
/// page cannot post as the runtime. No script is added here: the runtime is evaluated when the user
/// turns design mode on, so an idle tab pays nothing.
final class WebKitDesignModeHandler: NSObject, WKScriptMessageHandler {
    private weak var tab: WebKitTab?

    private init(tab: WebKitTab) { self.tab = tab }

    /// The controller keeps the handler; the handler keeps the tab weakly.
    static func install(on tab: WebKitTab, into controller: WKUserContentController) {
        controller.add(WebKitDesignModeHandler(tab: tab), contentWorld: .defaultClient, name: BrowserDesignModeScript.channel)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, JSONSerialization.isValidJSONObject(message.body),
              let data = try? CheckedJSON().data(message.body) else { return }
        tab?.emit(.designMode(data))
    }
}
