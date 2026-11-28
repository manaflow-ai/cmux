import CmuxNextBrowserCore
import Foundation

/// A page's alert, confirm or prompt as the shim sends it (`CEFShimEvent.jsDialog`).
nonisolated struct CEFJSDialogQuestion: Equatable, Sendable {
    let kind: BrowserPromptKind

    /// `type` 0 alert, 1 confirm, 2 prompt; `textJSON` {"message","default"}. Nil for an unknown type or bad JSON.
    init?(type: Int32, textJSON: String) {
        guard let data = textJSON.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let message = object["message"] as? String ?? ""
        switch type {
        case 0: kind = .alert(message: message)
        case 1: kind = .confirm(message: message)
        case 2: kind = .textInput(message: message, defaultText: object["default"] as? String)
        default: return nil
        }
    }

    /// The shim's answer (accept, text) for `response`.
    static func reply(_ response: BrowserPromptResponse) -> (accept: Bool, text: String) {
        switch response {
        case .accept: (true, "")
        case .text(let text): (true, text)
        default: (false, "")
        }
    }
}

/// alert, confirm and prompt of a Chromium tab with in-tree pages (fork API 36). The fork cancels a JavaScript
/// dialog of an in-tree page that no CEF handler takes (Chrome's own dialog would anchor to the page's headless
/// window), so the shim sends them to the tab (`cmux_shim_set_js_dialogs`, on while in-tree pages are active), which
/// asks in the same cmux dialog as a WebKit tab (`BrowserPromptDialogs`). Live step ff9c0eb4 (cmux19): in tree
/// `alert()` showed nothing, while off Chromium's "… says" window showed.
extension CEFTab {
    func jsDialogAsked(_ question: CEFJSDialogQuestion, token: Int32, origin: String) {
        let runtime = runtime
        // A closed tab answers its dismissal (Cancel) at once (`enqueuePrompt`).
        enqueuePrompt(question.kind, origin: Self.dialogOrigin(origin)) { response in
            let reply = CEFJSDialogQuestion.reply(response)
            _ = reply.text.withCString { runtime.shim?.jsDialogReply(token, reply.accept ? 1 : 0, $0) }
        }
    }

    /// Chromium ended the waiting questions (renderer gone, page navigated or closed): they go away; the shim
    /// already forgot their tokens, so the answers are ignored.
    func jsDialogsDismissed() {
        for prompt in pendingPrompts where prompt.kind.isJavaScriptDialog { prompt.respond(.cancel) }
    }

    /// The asking origin as Chrome names it ("example.com says"): scheme and host (and port), not the path.
    static func dialogOrigin(_ url: String) -> String {
        guard let parts = URLComponents(string: url), let host = parts.host, !host.isEmpty else { return url }
        return parts.port.map { "\(host):\($0)" } ?? host
    }
}

extension BrowserPromptKind {
    /// An alert, confirm or prompt.
    nonisolated var isJavaScriptDialog: Bool {
        switch self {
        case .alert, .confirm, .textInput: true
        default: false
        }
    }
}
