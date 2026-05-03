import Foundation
import WebKit

/// JS↔Swift bridge for the per-turn diff panel.
/// Pattern modelled on Sources/Panels/ReactGrab.swift:144-227.
enum TurnDiffBridgeMessage {
    case ready                  // JS finished mounting; Swift should send initial diff
    case diffRequest            // JS asks for the current diff (e.g. on remount)
    // v2/v3 will add: commentSubmit, editApply, editQueue

    init?(body: [String: Any]) {
        let type = body["type"] as? String ?? ""
        switch type {
        case "ready":          self = .ready
        case "diff-request":   self = .diffRequest
        default:               return nil
        }
    }
}

@MainActor
final class TurnDiffMessageHandler: NSObject, WKScriptMessageHandler {
    nonisolated static let handlerName = "cmuxTurnDiff"

    private let onMessage: @MainActor (TurnDiffBridgeMessage) -> Void

    init(onMessage: @escaping @MainActor (TurnDiffBridgeMessage) -> Void) {
        self.onMessage = onMessage
    }

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.handlerName,
              let body = message.body as? [String: Any],
              let parsed = TurnDiffBridgeMessage(body: body) else { return }
        Task { @MainActor in onMessage(parsed) }
    }
}

extension WKWebView {
    /// Dispatches a CustomEvent on window with the given JSON-serialisable detail.
    /// Used by Swift to push diff/status updates to the React app.
    func cmuxDispatchTurnDiff(eventName: String, detail: Any) {
        let detailLiteral: String
        if let s = detail as? String {
            // Encode string as a JSON string literal via single-element array trick.
            let encoded = (try? JSONSerialization.data(withJSONObject: [s], options: []))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
            detailLiteral = String(encoded.dropFirst().dropLast())  // strip [ and ]
        } else if JSONSerialization.isValidJSONObject(detail) {
            let data = (try? JSONSerialization.data(withJSONObject: detail, options: []))
                ?? Data()
            detailLiteral = String(data: data, encoding: .utf8) ?? "null"
        } else {
            detailLiteral = "null"
        }
        let escapedEventName = eventName.replacingOccurrences(of: "'", with: "\\'")
        let script = "window.dispatchEvent(new CustomEvent('\(escapedEventName)', { detail: \(detailLiteral) }));"
        evaluateJavaScript(script, completionHandler: nil)
    }
}
