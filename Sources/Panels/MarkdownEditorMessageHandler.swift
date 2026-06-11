import Foundation
import WebKit

/// JS→Swift bridge for the markdown panel's in-panel Monaco editor page
/// (`window.webkit.messageHandlers.cmuxEditorSave`).
///
/// Unlike the browser-path ``EditorSaveMessageHandler`` (which resolves a
/// write target from the `cmux edit` token registry), this handler is bound to
/// a single panel at construction and only accepts messages from the main
/// frame served at that panel's editor origin
/// (`cmux-markdown-editor://<token>`). The disk write itself happens in
/// `MarkdownPanel.performEditorSave`, so the markdown panel keeps one
/// authoritative save path; this handler never touches the filesystem.
final class MarkdownEditorMessageHandler: NSObject, WKScriptMessageHandlerWithReply {
    static let handlerName = "cmuxEditorSave"

    private let expectedOriginToken: String
    /// Receives the page's dirty state plus the mirrored live buffer.
    private let onContentMirrored: @MainActor (Bool, String?) -> Void
    /// Performs the panel save and returns the page-facing reply envelope.
    private let onSave: @MainActor (_ content: String, _ expectedSha256: String?, _ force: Bool) async -> [String: Any]

    init(
        expectedOriginToken: String,
        onContentMirrored: @escaping @MainActor (Bool, String?) -> Void,
        onSave: @escaping @MainActor (_ content: String, _ expectedSha256: String?, _ force: Bool) async -> [String: Any]
    ) {
        self.expectedOriginToken = expectedOriginToken
        self.onContentMirrored = onContentMirrored
        self.onSave = onSave
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard Self.isAuthorizedFrame(message, expectedOriginToken: expectedOriginToken) else {
            replyHandler(["error": ["code": "unauthorized"]], nil)
            return
        }
        guard let body = message.body as? [String: Any] else {
            replyHandler(["error": ["code": "invalid_request"]], nil)
            return
        }
        // Capability probe at mount time: the panel generated this page with a
        // live save route, so a writable page always probes writable.
        if body["probe"] as? Bool == true {
            replyHandler(["ok": true, "value": ["status": "writable"]], nil)
            return
        }
        if let dirty = body["dirty"] as? Bool {
            let mirroredContent = body["content"] as? String
            // WebKit delivers script messages on the main thread.
            MainActor.assumeIsolated {
                onContentMirrored(dirty, mirroredContent)
            }
            replyHandler(["ok": true, "value": ["status": "ok"]], nil)
            return
        }
        guard let content = body["content"] as? String else {
            replyHandler(["error": ["code": "invalid_request"]], nil)
            return
        }
        let expectedSha256 = body["expectedSha256"] as? String
        let force = body["force"] as? Bool ?? false
        let onSave = onSave
        Task { @MainActor in
            let envelope = await onSave(content, expectedSha256, force)
            replyHandler(envelope, nil)
        }
    }

    /// Only the main frame served at this panel's own editor origin may talk
    /// to the bridge; any other page in the webview resolves nothing.
    static func isAuthorizedFrame(_ message: WKScriptMessage, expectedOriginToken: String) -> Bool {
        guard message.frameInfo.isMainFrame else { return false }
        let origin = message.frameInfo.securityOrigin
        return origin.protocol == MarkdownEditorSchemeHandler.scheme && origin.host == expectedOriginToken
    }
}
