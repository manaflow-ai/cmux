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
        // Resolve symlinks so the atomic save rewrites the link's TARGET; an
        // atomic write to the link path itself would replace the symlink node
        // with a regular file and silently orphan the target.
        let standardized = fileURL.standardizedFileURL.resolvingSymlinksInPath()
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
        guard let token = Self.editorToken(for: message),
              let fileURL = CmuxEditorSaveRegistry.shared.fileURL(forToken: token) else {
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

    /// Extracts the page's diff-viewer serving token from the WebKit-reported
    /// frame identity (never from the message body). Two serving modes:
    /// custom scheme pages carry the token as the origin host; localhost
    /// HTTP-server pages carry it as the first path component of the frame
    /// URL (the page cannot forge `frameInfo.request.url`). The token is an
    /// unguessable per-open capability; the registry lookup is what
    /// authorizes the write.
    private static func editorToken(for message: WKScriptMessage) -> String? {
        guard message.frameInfo.isMainFrame else { return nil }
        let origin = message.frameInfo.securityOrigin
        if origin.protocol == CmuxDiffViewerURLSchemeHandler.scheme {
            return origin.host
        }
        if origin.protocol == "http", origin.host == "127.0.0.1" {
            // The token is the first path component of the main-frame URL.
            // Read it from the webview (WebKit-owned, matches the main frame
            // for main-frame messages); `frameInfo.request.url` is empty for
            // script messages on some WebKit versions. No fragment check: the
            // hash router rewrites it and it is not the security boundary;
            // the unguessable token + registry lookup below is.
            guard let frameURL = message.webView?.url else { return nil }
            let components = frameURL.path.split(separator: "/", omittingEmptySubsequences: true)
            return components.first.map(String.init)
        }
        return nil
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
            try replacePreservingMetadata(fileURL: fileURL, with: data)
        } catch let error as NSError {
            let code = error.domain == NSCocoaErrorDomain && error.code == NSFileWriteNoPermissionError
                ? "permission_denied"
                : "write_failed"
            return errorEnvelope(code: code, detail: error.localizedDescription)
        }
        return ["ok": true, "value": ["status": "saved", "sha256": sha256Hex(data)]]
    }

    /// Atomically replaces `fileURL` with `data` while keeping the original
    /// item's metadata (permissions/executable bit, xattrs), via
    /// `FileManager.replaceItemAt` and its system-provided replacement
    /// directory on the same volume. A bare `Data.write(.atomic)` would mint
    /// a fresh inode with default metadata and needs create rights in the
    /// file's own directory.
    private static func replacePreservingMetadata(fileURL: URL, with data: Data) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else {
            // Force-save after the file was deleted on disk: there is no
            // original to preserve metadata from, so recreate it directly
            // (this is the resolution path for the file-missing conflict).
            try data.write(to: fileURL, options: .atomic)
            return
        }
        let replacementDirectory = try fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: fileURL,
            create: true
        )
        defer { try? fileManager.removeItem(at: replacementDirectory) }
        let temporaryURL = replacementDirectory.appendingPathComponent(fileURL.lastPathComponent)
        try data.write(to: temporaryURL)
        _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporaryURL)
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
