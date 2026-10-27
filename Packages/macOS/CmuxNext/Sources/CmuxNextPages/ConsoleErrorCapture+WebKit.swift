public import CmuxNextErrorJournal
import Foundation
import os
public import WebKit

extension ConsoleErrorCapture {
    /// Adds ``ConsoleErrorCapture/script`` and its message handler to `controller`: a WebKit page's
    /// reports reach the unified log, where the journal harvests them.
    ///
    /// ```swift
    /// ConsoleErrorCapture(page: "settings").install(in: configuration.userContentController)
    /// ```
    public func install(in controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: .page))
        controller.add(ConsoleErrorReceiver(page: page), contentWorld: .page, name: Self.handlerName)
    }
}

/// Receives the page's reports and logs them; main-frame reports only.
private final class ConsoleErrorReceiver: NSObject, WKScriptMessageHandler {
    let logger: Logger

    init(page: String) {
        logger = Logger(subsystem: ConsoleErrorCapture.subsystem, category: page)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any] else { return }
        let text = ConsoleErrorCapture.logText(level: body["level"] as? String ?? "error",
                                               message: body["message"] as? String ?? "",
                                               stack: body["stack"] as? String ?? "")
        // Redacted above, so public: the journal must read the text back.
        logger.error("\(text, privacy: .public)")
    }
}
