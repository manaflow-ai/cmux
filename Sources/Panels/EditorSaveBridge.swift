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
        let expectedOrigin: String
        let createdAt: Date
        /// Pins the capability against TTL reaping while the page has unsaved
        /// changes. An editor reports `dirty` whenever its buffer diverges from
        /// disk, and once dirty the page goes quiet (no periodic ping), so a
        /// plain sliding TTL would reap an editor left idle with unsaved work
        /// past `maxEntryAge` and then refuse to save it. While this is true the
        /// entry never expires; it clears when the page reports a clean buffer
        /// (after a save or revert).
        let hasUnsavedChanges: Bool
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let maxEntryAge: TimeInterval = 24 * 60 * 60

    /// An entry is live while it has unsaved changes (pinned) or is still within
    /// the sliding TTL. Reaping only ever drops clean, abandoned registrations.
    private func isLive(_ entry: Entry, now: Date) -> Bool {
        entry.hasUnsavedChanges || now.timeIntervalSince(entry.createdAt) < maxEntryAge
    }

    /// The uid-owned diff-viewer serving directory (same trust root as
    /// ``CmuxDiffViewerURLSchemeHandler``). Only same-uid processes can write
    /// here, so its 0600 `.editor-<token>.json` sidecars are proof that a
    /// real `cmux edit` minted the write capability; socket callers cannot
    /// forge one through `browser.open_split` params.
    private let trustedRootURL: URL

    /// The process-wide default serving directory. Tests inject a temp root
    /// through ``init(trustedRootURL:)`` to exercise the sidecar round-trips
    /// without touching the shared `/tmp` directory.
    static let defaultTrustedRootURL = URL(fileURLWithPath: "/tmp", isDirectory: true)
        .appendingPathComponent("cmux-diff-viewer-\(Darwin.getuid())", isDirectory: true)
        .standardizedFileURL
        .resolvingSymlinksInPath()

    init(trustedRootURL: URL = CmuxEditorSaveRegistry.defaultTrustedRootURL) {
        self.trustedRootURL = trustedRootURL
    }

    /// Registers the write target for `token` from its trusted sidecar, if
    /// one exists. Returns whether a capability was registered. Tokens with
    /// no sidecar (plain diff viewers, read-only opens) are not an error.
    @discardableResult
    func registerFromTrustedSidecar(token: String) -> Bool {
        guard CmuxDiffViewerURLSchemeHandler.isValidToken(token) else { return false }
        let sidecarURL = trustedRootURL.appendingPathComponent(".editor-\(token).json", isDirectory: false)
        guard let data = try? Data(contentsOf: sidecarURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              object["token"] == token,
              let path = object["path"], path.hasPrefix("/"),
              let origin = object["origin"], !origin.isEmpty else {
            return false
        }
        do {
            try register(token: token, fileURL: URL(fileURLWithPath: path), expectedOrigin: origin)
            // One-shot capability handoff: the registration lives in memory
            // for this app instance and pages restored after a relaunch are
            // read-only by design, so the sidecar is deleted once consumed
            // instead of accumulating in the serving directory.
            try? FileManager.default.removeItem(at: sidecarURL)
            return true
        } catch {
            return false
        }
    }

    func register(token: String, fileURL: URL, expectedOrigin: String, now: Date = Date()) throws {
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
        entries = entries.filter { isLive($0.value, now: now) }
        entries[token] = Entry(
            fileURL: standardized,
            expectedOrigin: expectedOrigin,
            createdAt: now,
            hasUnsavedChanges: false
        )
    }

    /// Resolves the write target for `token`, but only when the requesting
    /// page's serving origin matches the one the capability was minted for
    /// (exact scheme/host/port, so a localhost page on another port that
    /// learned a live token still resolves nothing).
    func fileURL(forToken token: String, requestOrigin: String, now: Date = Date()) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[token],
              isLive(entry, now: now),
              entry.expectedOrigin == requestOrigin else {
            return nil
        }
        // Sliding expiry: every authorized access (probe, dirty report, save)
        // renews the entry, so the TTL only reaps abandoned registrations.
        // Editors with unsaved changes are additionally pinned (see Entry), so
        // even a long-idle dirty buffer never silently loses its save capability.
        entries[token] = Entry(
            fileURL: entry.fileURL,
            expectedOrigin: entry.expectedOrigin,
            createdAt: now,
            hasUnsavedChanges: entry.hasUnsavedChanges
        )
        return entry.fileURL
    }

    /// Records whether the page for `token` currently has unsaved changes,
    /// pinning the capability against TTL reaping while it does. Authorized by
    /// origin like every other access, and slides the entry. A no-op for an
    /// unknown token or origin mismatch.
    func setUnsavedChanges(_ unsaved: Bool, forToken token: String, requestOrigin: String, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[token], entry.expectedOrigin == requestOrigin else {
            return
        }
        entries[token] = Entry(
            fileURL: entry.fileURL,
            expectedOrigin: entry.expectedOrigin,
            createdAt: now,
            hasUnsavedChanges: unsaved
        )
    }

    /// Sidecar for an editor page's Monaco view state (scroll/cursor/selection/
    /// folding), keyed by serving token, in the uid-owned serving directory.
    private func viewStateSidecarURL(forToken token: String) -> URL {
        trustedRootURL.appendingPathComponent(".viewstate-\(token).json", isDirectory: false)
    }

    /// A view-state token is authorized only when a real diff-viewer/editor page
    /// was served under it, proven by its `.manifest-<token>.json` existing in
    /// the uid-owned serving directory (`cmux edit`/`cmux diff` write one for
    /// every served page; the manifest persists across restore). Without this,
    /// any same-origin-shaped localhost page with a token-shaped path component
    /// could write/overwrite arbitrary `.viewstate-<token>.json` files. A valid
    /// token syntax alone is not enough.
    private func tokenHasServedManifest(_ token: String) -> Bool {
        guard CmuxDiffViewerURLSchemeHandler.isValidToken(token) else { return false }
        let manifestURL = trustedRootURL.appendingPathComponent(".manifest-\(token).json", isDirectory: false)
        return FileManager.default.fileExists(atPath: manifestURL.path)
    }

    /// Persists opaque Monaco view state for an editor page. Unlike the write
    /// capability, this is keyed by the page's scheme token (the handler
    /// authorizes it from the unforgeable frame identity, and the token must map
    /// to a real served page), so scroll memory works for read-only files too.
    /// Written 0600 next to `.editor-<token>`.
    @discardableResult
    func storeViewState(_ data: Data, forToken token: String) -> Bool {
        guard tokenHasServedManifest(token) else { return false }
        let url = viewStateSidecarURL(forToken: token)
        do {
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }

    /// Reads the persisted view-state sidecar for `token`, or nil when absent or
    /// when no real page was served under `token`.
    func loadViewState(forToken token: String) -> Data? {
        guard tokenHasServedManifest(token) else { return nil }
        return try? Data(contentsOf: viewStateSidecarURL(forToken: token))
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

    /// Receives the page's buffer dirty state (already token-authorized) so
    /// the native panel can drive close-confirmation and tab metadata.
    private let onDirtyChanged: @MainActor (Bool) -> Void

    init(onDirtyChanged: @escaping @MainActor (Bool) -> Void) {
        self.onDirtyChanged = onDirtyChanged
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard let (token, requestOrigin) = Self.editorTokenAndOrigin(for: message) else {
            replyHandler(Self.errorEnvelope(code: "unauthorized", detail: nil), nil)
            return
        }
        guard let body = message.body as? [String: Any] else {
            replyHandler(Self.errorEnvelope(code: "invalid_request", detail: nil), nil)
            return
        }
        // View-state round-trip (scroll/cursor/selection/folding). Authorized by
        // the page's scheme token from the unforgeable frame identity, NOT the
        // write capability, so scroll memory works for read-only files. The
        // payload is opaque Monaco state persisted to a per-token sidecar.
        if body["loadViewState"] as? Bool == true {
            Self.ioQueue.async {
                let viewState = CmuxEditorSaveRegistry.shared.loadViewState(forToken: token)
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) }
                DispatchQueue.main.async {
                    replyHandler(["ok": true, "value": ["viewState": viewState as Any]], nil)
                }
            }
            return
        }
        if body.keys.contains("viewState") {
            let viewState = body["viewState"]
            Self.ioQueue.async {
                if let obj = viewState as? [String: Any],
                   let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) {
                    CmuxEditorSaveRegistry.shared.storeViewState(data, forToken: token)
                }
                // A null/absent viewState is a no-op: keep the last good state.
                DispatchQueue.main.async {
                    replyHandler(["ok": true, "value": ["status": "ok"]], nil)
                }
            }
            return
        }
        // Everything below mutates the user's file and requires the write
        // capability (origin-bound, TTL-managed). Read-only pages stop here.
        guard let fileURL = CmuxEditorSaveRegistry.shared.fileURL(forToken: token, requestOrigin: requestOrigin) else {
            replyHandler(Self.errorEnvelope(code: "unauthorized", detail: nil), nil)
            return
        }
        // Capability probe: the page asks at mount time whether this token
        // still has a live write registration, so a restored page whose
        // registration died with the previous app instance opens read-only
        // instead of accepting edits it can never save. Reaching this point
        // means the registry lookup above succeeded.
        if body["probe"] as? Bool == true {
            replyHandler(["ok": true, "value": ["status": "writable"]], nil)
            return
        }
        if let dirty = body["dirty"] as? Bool {
            // Pin the capability against TTL reaping while the buffer is dirty:
            // an editor goes quiet once dirty, so without this an idle unsaved
            // buffer past the TTL would lose its save capability.
            CmuxEditorSaveRegistry.shared.setUnsavedChanges(dirty, forToken: token, requestOrigin: requestOrigin)
            // WebKit delivers script messages on the main thread.
            MainActor.assumeIsolated {
                onDirtyChanged(dirty)
            }
            replyHandler(["ok": true, "value": ["status": "ok"]], nil)
            return
        }
        guard let content = body["content"] as? String else {
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
    private static func editorTokenAndOrigin(for message: WKScriptMessage) -> (token: String, origin: String)? {
        guard message.frameInfo.isMainFrame else { return nil }
        let origin = message.frameInfo.securityOrigin
        if origin.protocol == CmuxDiffViewerURLSchemeHandler.scheme {
            return (token: origin.host, origin: "\(origin.protocol)://\(origin.host)")
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
            guard let token = components.first.map(String.init) else { return nil }
            return (token: token, origin: "http://127.0.0.1:\(origin.port)")
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

    private static let hexDigits = Array("0123456789abcdef".utf8)

    private static func sha256Hex(_ data: Data) -> String {
        // Pure Swift nibble encoding: String(format:) in hash paths is the
        // known unbounded-memory P0 class in this repo.
        var out = [UInt8]()
        out.reserveCapacity(64)
        for byte in SHA256.hash(data: data) {
            out.append(hexDigits[Int(byte >> 4)])
            out.append(hexDigits[Int(byte & 0x0f)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}

extension BrowserPanel {
    /// Installs the `cmux edit` save endpoint on `webView`. The handler
    /// authorizes purely by frame origin + token registry, so it is safe to
    /// expose on every browser webview; pages that were not opened by
    /// `cmux edit` resolve no write target. Authorized dirty-state messages
    /// feed the native panel so tab close-confirmation sees unsaved edits.
    func setupEditorSaveMessageHandler(for webView: WKWebView) {
        webView.configuration.userContentController.addScriptMessageHandler(
            EditorSaveMessageHandler { [weak self] dirty in
                // Any dirty report (true or false, incl. the one sent on mount)
                // means an editor page is live in this webview.
                self?.editorPageActive = true
                self?.editorBufferIsDirty = dirty
            },
            contentWorld: .page,
            name: EditorSaveMessageHandler.handlerName
        )
    }

    /// Routes editor key equivalents to the Monaco page so the app's standard
    /// Edit menu never shadows the editor: the configurable `saveFilePreview`
    /// shortcut triggers a save, and the standard undo/redo chords drive
    /// Monaco's own model undo/redo (WKWebView's native `undo:` does nothing
    /// useful for a Monaco buffer). Returns whether the event was consumed.
    func handleEditorKeyEquivalent(event: NSEvent, webView: WKWebView) -> Bool {
        // Save: configurable shortcut, gated on a dirty buffer / chord prefix.
        if editorBufferIsDirty || editorSaveChordPrefixPending {
            let shortcut = KeyboardShortcutSettings.shortcut(for: .saveFilePreview)
            var saveMatched = false
            if shortcut.hasChord {
                if editorSaveChordPrefixPending {
                    editorSaveChordPrefixPending = false
                    if let secondStroke = shortcut.secondStroke, secondStroke.matches(event: event) {
                        saveMatched = true
                    }
                } else if shortcut.firstStroke.matches(event: event) {
                    editorSaveChordPrefixPending = true
                    return true
                }
            } else if shortcut.matches(event: event) {
                saveMatched = true
            }
            if saveMatched {
                webView.evaluateJavaScript("window.__cmuxEditorRequestSave && window.__cmuxEditorRequestSave();")
                return true
            }
        }
        // Undo / redo: only when an editor page is live in this webview.
        guard editorPageActive else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let shift = flags.contains(.shift)
        let key = event.charactersIgnoringModifiers?.lowercased()
        guard command, !flags.contains(.option), !flags.contains(.control) else { return false }
        if key == "z", !shift {
            webView.evaluateJavaScript("window.__cmuxEditorUndo && window.__cmuxEditorUndo();")
            return true
        }
        if (key == "z" && shift) || key == "y" {
            webView.evaluateJavaScript("window.__cmuxEditorRedo && window.__cmuxEditorRedo();")
            return true
        }
        return false
    }
}
