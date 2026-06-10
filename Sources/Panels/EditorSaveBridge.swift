import CryptoKit
import Foundation
import WebKit

/// Token-scoped write capabilities for `cmux edit` surfaces.
///
/// `cmux edit` registers the edited file's URL under the page's diff-viewer
/// scheme token (via `browser.open_split`'s `editor_file` param), and the save
/// message handler resolves the write target from this registry using the
/// *page's* security origin. The file path therefore always comes from the
/// trusted CLI open call, never from page JavaScript: a page can only ever
/// write the one file that was registered for the token it was served under.
final class CmuxEditorSaveRegistry: @unchecked Sendable {
    static let shared = CmuxEditorSaveRegistry()

    private struct Entry {
        let fileURL: URL
        let createdAt: Date
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let maxEntryAge: TimeInterval = 24 * 60 * 60

    func register(token: String, fileURL: URL, now: Date = Date()) throws {
        guard CmuxDiffViewerURLSchemeHandler.isValidToken(token) else {
            throw NSError(domain: "CmuxEditorSaveRegistry", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Invalid editor token"
            ])
        }
        let standardized = fileURL.standardizedFileURL
        guard standardized.isFileURL, standardized.path.hasPrefix("/") else {
            throw NSError(domain: "CmuxEditorSaveRegistry", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Editor file path must be absolute"
            ])
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw NSError(domain: "CmuxEditorSaveRegistry", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Editor file does not exist"
            ])
        }
        lock.lock()
        defer { lock.unlock() }
        entries = entries.filter { now.timeIntervalSince($0.value.createdAt) < maxEntryAge }
        entries[token] = Entry(fileURL: standardized, createdAt: now)
    }

    func fileURL(forToken token: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[token],
              Date().timeIntervalSince(entry.createdAt) < maxEntryAge else {
            return nil
        }
        return entry.fileURL
    }
}

/// JS→Swift save endpoint for the Monaco editor surface
/// (`window.webkit.messageHandlers.cmuxEditorSave.postMessage(...)`).
///
/// Authorization model: the handler trusts nothing in the message body except
/// the buffer content. The write target is resolved from the *frame's*
/// security origin (custom diff-viewer scheme + token host) through
/// ``CmuxEditorSaveRegistry``; arbitrary web pages in the same browser panel
/// have a different origin and resolve to nothing.
///
/// Conflict model: every save carries the SHA-256 of the content the buffer
/// was last synced from. A mismatch against the bytes currently on disk (or a
/// missing file) refuses the write and returns the disk state so the page can
/// offer "overwrite" (`force: true`) or "use disk version".
final class EditorSaveMessageHandler: NSObject, WKScriptMessageHandlerWithReply {
    static let handlerName = "cmuxEditorSave"

    private static let ioQueue = DispatchQueue(label: "com.manaflow.cmux.editor-save", qos: .userInitiated)

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol == CmuxDiffViewerURLSchemeHandler.scheme,
              let fileURL = CmuxEditorSaveRegistry.shared.fileURL(
                forToken: message.frameInfo.securityOrigin.host
              ) else {
            replyHandler(Self.errorEnvelope(code: "unauthorized", detail: nil), nil)
            return
        }
        guard let body = message.body as? [String: Any],
              let content = body["content"] as? String else {
            replyHandler(Self.errorEnvelope(code: "invalid_request", detail: nil), nil)
            return
        }
        let expectedSha256 = body["expectedSha256"] as? String
        let force = body["force"] as? Bool ?? false

        Self.ioQueue.async {
            let envelope = Self.performSave(
                fileURL: fileURL,
                content: content,
                expectedSha256: expectedSha256,
                force: force
            )
            DispatchQueue.main.async {
                replyHandler(envelope, nil)
            }
        }
    }

    private static func performSave(
        fileURL: URL,
        content: String,
        expectedSha256: String?,
        force: Bool
    ) -> [String: Any] {
        let diskData = try? Data(contentsOf: fileURL)
        if !force {
            guard let diskData else {
                return conflictEnvelope(fileMissing: true, diskData: nil)
            }
            let diskSha = sha256Hex(diskData)
            if let expectedSha256, !expectedSha256.isEmpty, diskSha != expectedSha256 {
                return conflictEnvelope(fileMissing: false, diskData: diskData)
            }
        }
        let data = Data(content.utf8)
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch let error as NSError {
            let code = error.domain == NSCocoaErrorDomain && error.code == NSFileWriteNoPermissionError
                ? "permission_denied"
                : "write_failed"
            return errorEnvelope(code: code, detail: error.localizedDescription)
        }
        return ["ok": true, "value": ["status": "saved", "sha256": sha256Hex(data)]]
    }

    private static func conflictEnvelope(fileMissing: Bool, diskData: Data?) -> [String: Any] {
        var value: [String: Any] = ["status": "conflict", "fileMissing": fileMissing]
        if let diskData {
            value["diskSha256"] = sha256Hex(diskData)
            if let diskContent = String(data: diskData, encoding: .utf8) {
                value["diskContent"] = diskContent
            }
        }
        return ["ok": true, "value": value]
    }

    private static func errorEnvelope(code: String, detail: String?) -> [String: Any] {
        var error: [String: Any] = ["code": code]
        if let detail {
            error["detail"] = detail
        }
        return ["error": error]
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension BrowserPanel {
    /// Installs the `cmux edit` save endpoint on `webView`. The handler is
    /// stateless and authorizes purely by frame origin + token registry, so it
    /// is safe to expose on every browser webview; pages that were not opened
    /// by `cmux edit` resolve no write target.
    func setupEditorSaveMessageHandler(for webView: WKWebView) {
        webView.configuration.userContentController.addScriptMessageHandler(
            EditorSaveMessageHandler(),
            contentWorld: .page,
            name: EditorSaveMessageHandler.handlerName
        )
    }
}
