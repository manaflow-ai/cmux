import Foundation
import Combine
import WebKit
import AppKit
import Bonsplit
import Network
import CFNetwork
import SQLite3
import CryptoKit
import Darwin
#if canImport(CommonCrypto)
import CommonCrypto
#endif
#if canImport(Security)
import Security
#endif


// MARK: - Diff viewer URL scheme handler
final class CmuxDiffViewerURLSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "cmux-diff-viewer"
    static let shared = CmuxDiffViewerURLSchemeHandler()
    static let maxRegisteredFiles = 1024

    struct RegisteredFile {
        let requestPath: String
        let fileURL: URL
        let mimeType: String
    }

    private struct Session {
        let filesByPath: [String: RegisteredFile]
        let createdAt: Date
    }

    private final class SchemeTaskState: @unchecked Sendable {
        let condition = NSCondition()
        var isStopped = false
        var callbacksInFlight = 0
    }

    private let lock = NSLock()
    private var sessions: [String: Session] = [:]
    private var activeSchemeTasks: [ObjectIdentifier: SchemeTaskState] = [:]
    private let streamQueue = DispatchQueue(label: "com.manaflow.cmux.diff-viewer-stream", qos: .userInitiated)
    private let maxSessionAge: TimeInterval = 24 * 60 * 60
    private let trustedRootURL = URL(fileURLWithPath: "/tmp", isDirectory: true)
        .appendingPathComponent("cmux-diff-viewer-\(Darwin.getuid())", isDirectory: true)
        .standardizedFileURL
        .resolvingSymlinksInPath()

    func register(token: String, files: [RegisteredFile], now: Date = Date()) throws {
        guard Self.isValidToken(token) else {
            throw NSError(domain: "CmuxDiffViewerURLSchemeHandler", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Invalid diff viewer token"
            ])
        }
        guard !files.isEmpty else {
            throw NSError(domain: "CmuxDiffViewerURLSchemeHandler", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Diff viewer allowlist is empty"
            ])
        }

        var byPath: [String: RegisteredFile] = [:]
        for file in files {
            guard Self.isValidRequestPath(file.requestPath),
                  Self.isAllowedMimeType(file.mimeType),
                  Self.pathExtensionMatchesMimeType(path: file.requestPath, mimeType: file.mimeType) else {
                throw NSError(domain: "CmuxDiffViewerURLSchemeHandler", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "Invalid diff viewer allowlist entry"
                ])
            }

            let standardizedURL = file.fileURL.standardizedFileURL.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard isTrustedDiffViewerFileURL(standardizedURL),
                  FileManager.default.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  FileManager.default.isReadableFile(atPath: standardizedURL.path) else {
                throw NSError(domain: "CmuxDiffViewerURLSchemeHandler", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "Diff viewer file is not readable"
                ])
            }
            guard byPath[file.requestPath] == nil else {
                throw NSError(domain: "CmuxDiffViewerURLSchemeHandler", code: 5, userInfo: [
                    NSLocalizedDescriptionKey: "Duplicate diff viewer allowlist entry"
                ])
            }

            byPath[file.requestPath] = RegisteredFile(
                requestPath: file.requestPath,
                fileURL: standardizedURL,
                mimeType: file.mimeType
            )
        }

        lock.lock()
        pruneExpiredSessionsLocked(now: now)
        sessions[token] = Session(filesByPath: byPath, createdAt: now)
        lock.unlock()
    }

    func registeredFile(for url: URL, now: Date = Date()) -> RegisteredFile? {
        guard url.scheme == Self.scheme,
              let token = url.host,
              url.query == nil,
              url.fragment == nil,
              Self.isValidToken(token) else {
            return nil
        }
        guard let requestPath = Self.requestPath(for: url) else {
            return nil
        }

        lock.lock()
        pruneExpiredSessionsLocked(now: now)
        let file = sessions[token]?.filesByPath[requestPath]
        lock.unlock()
        return file
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url,
              let file = registeredFile(for: requestURL) else {
            urlSchemeTask.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist))
            return
        }

        startStreamingFile(file, requestURL: requestURL, urlSchemeTask: urlSchemeTask)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        let taskID = ObjectIdentifier(urlSchemeTask as AnyObject)
        stopSchemeTask(taskID)
    }

    static func registeredFile(from object: [String: Any]) -> RegisteredFile? {
        guard let requestPath = object["request_path"] as? String,
              let filePath = object["file_path"] as? String,
              let mimeType = object["mime_type"] as? String else {
            return nil
        }
        return RegisteredFile(
            requestPath: requestPath,
            fileURL: URL(fileURLWithPath: filePath, isDirectory: false),
            mimeType: mimeType
        )
    }

    /// Re-registers a diff viewer token from its on-disk manifest so the surface
    /// can be served again after an app restart (the in-memory registry is lost,
    /// but the manifest + files persist in the trusted diff viewer directory).
    /// Returns `true` when the token is registered and ready to serve.
    func registerFromManifest(token: String, now: Date = Date()) -> Bool {
        guard let files = localManifestFiles(token: token) else { return false }
        do {
            try register(token: token, files: files, now: now)
            return true
        } catch {
            return false
        }
    }

    /// Loads the registered files for a token's on-disk manifest, or `nil` when
    /// the manifest is missing, empty, or references remote patch entries
    /// (`remote_url` / empty `file_path`) that the local-file scheme handler
    /// cannot serve. Streamed remote PR diffs fall into the latter case.
    private func localManifestFiles(token: String) -> [RegisteredFile]? {
        guard Self.isValidToken(token) else { return nil }
        let manifestURL = trustedRootURL.appendingPathComponent(".manifest-\(token).json", isDirectory: false)
        guard let data = try? Data(contentsOf: manifestURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fileObjects = object["files"] as? [[String: Any]],
              !fileObjects.isEmpty else {
            return nil
        }
        var files: [RegisteredFile] = []
        for fileObject in fileObjects {
            let filePath = fileObject["file_path"] as? String ?? ""
            if fileObject["remote_url"] is String || filePath.isEmpty {
                return nil
            }
            guard let file = Self.registeredFile(from: fileObject) else { return nil }
            files.append(file)
        }
        return files
    }

    /// Whether a diff viewer surface can be restored through the custom scheme.
    /// Requires a local-only manifest and an entry page that is neither a
    /// pending placeholder nor a redirect stub. Pending pages poll a
    /// deferred-load wait endpoint, and redirect pages bounce to the original
    /// `http://127.0.0.1:<port>` URL; both only work against the local HTTP
    /// server, which is gone after restart, so they would fail under the
    /// custom scheme.
    func diffViewerRestorable(token: String, requestPath: String) -> Bool {
        guard let files = localManifestFiles(token: token),
              let entry = files.first(where: { $0.requestPath == requestPath }),
              let handle = try? FileHandle(forReadingFrom: entry.fileURL) else {
            return false
        }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 1024)) ?? Data()
        if let text = String(data: head, encoding: .utf8),
           text.contains("data-cmux-diff-pending=\"true\"") || text.contains("data-cmux-diff-redirect") {
            return false
        }
        return true
    }

    /// Extracts the diff viewer `(token, requestPath)` from a live diff viewer
    /// URL, accepting both the custom scheme (`cmux-diff-viewer://<token>/<path>`)
    /// and the local HTTP server form (`http://127.0.0.1:<port>/<token>/<path>#cmux-diff-viewer`).
    static func diffViewerComponents(from url: URL?) -> (token: String, requestPath: String)? {
        guard let url else { return nil }
        if url.scheme == scheme, let token = url.host, isValidToken(token) {
            guard let requestPath = requestPath(for: url) else { return nil }
            return (token, requestPath)
        }
        if (url.scheme == "http" || url.scheme == "https"),
           url.host == "127.0.0.1",
           url.fragment == Self.scheme {
            let rawPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
            let parts = rawPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 2, isValidToken(parts[0]) else { return nil }
            let requestPath = "/" + parts.dropFirst().joined(separator: "/")
            guard isValidRequestPath(requestPath) else { return nil }
            return (parts[0], requestPath)
        }
        return nil
    }

    /// Builds the app-owned custom-scheme URL used to restore a diff viewer
    /// surface, decoupled from the local HTTP server. No fragment, so
    /// `registeredFile(for:)` serves it.
    static func diffViewerURL(token: String, requestPath: String) -> URL? {
        guard isValidToken(token), isValidRequestPath(requestPath) else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = token
        components.percentEncodedPath = requestPath
        return components.url
    }

    static func isValidToken(_ token: String) -> Bool {
        guard (16...80).contains(token.count) else { return false }
        return token.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-"
        }
    }

    static func isValidRequestPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"),
              !path.contains("\\"),
              !path.contains("//") else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard !components.isEmpty else { return false }
        return components.allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
        }
    }

    static func requestPath(for url: URL) -> String? {
        let rawPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        let requestPath = rawPath.isEmpty ? "/" : rawPath
        guard isValidRequestPath(requestPath) else { return nil }
        return requestPath
    }

    private static func isAllowedMimeType(_ mimeType: String) -> Bool {
        mimeType == "text/html" || mimeType == "text/javascript" || mimeType == "text/x-diff"
    }

    private static func pathExtensionMatchesMimeType(path: String, mimeType: String) -> Bool {
        if mimeType == "text/html" {
            return path.hasSuffix(".html")
        }
        if mimeType == "text/javascript" {
            return path.hasSuffix(".mjs") || path.hasSuffix(".js")
        }
        if mimeType == "text/x-diff" {
            return path.hasSuffix(".patch")
        }
        return false
    }

    private func startStreamingFile(
        _ file: RegisteredFile,
        requestURL: URL,
        urlSchemeTask: WKURLSchemeTask
    ) {
        let taskID = ObjectIdentifier(urlSchemeTask as AnyObject)
        let state = SchemeTaskState()
        lock.lock()
        activeSchemeTasks[taskID] = state
        lock.unlock()

        streamQueue.async { [weak self] in
            guard let self else { return }
            do {
                let response = HTTPURLResponse(
                    url: requestURL,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: self.responseHeaders(for: file)
                ) ?? URLResponse(
                    url: requestURL,
                    mimeType: file.mimeType,
                    expectedContentLength: Self.fileSize(for: file.fileURL),
                    textEncodingName: "utf-8"
                )

                guard self.performSchemeTaskCallback(taskID, {
                    urlSchemeTask.didReceive(response)
                }) else { return }

                let handle = try FileHandle(forReadingFrom: file.fileURL)
                defer {
                    try? handle.close()
                }

                while self.isSchemeTaskActive(taskID) {
                    let data = try handle.read(upToCount: 64 * 1024) ?? Data()
                    if data.isEmpty {
                        break
                    }
                    guard self.performSchemeTaskCallback(taskID, {
                        urlSchemeTask.didReceive(data)
                    }) else { return }
                }

                guard self.performSchemeTaskCallback(taskID, {
                    urlSchemeTask.didFinish()
                }) else { return }
                self.finishSchemeTask(taskID)
            } catch {
                guard self.performSchemeTaskCallback(taskID, {
                    urlSchemeTask.didFailWithError(error)
                }) else { return }
                self.finishSchemeTask(taskID)
            }
        }
    }

    private func isSchemeTaskActive(_ taskID: ObjectIdentifier) -> Bool {
        lock.lock()
        let state = activeSchemeTasks[taskID]
        lock.unlock()
        guard let state else { return false }

        state.condition.lock()
        let active = !state.isStopped
        state.condition.unlock()
        return active
    }

    private func performSchemeTaskCallback(_ taskID: ObjectIdentifier, _ callback: () -> Void) -> Bool {
        lock.lock()
        let state = activeSchemeTasks[taskID]
        lock.unlock()
        guard let state else { return false }

        state.condition.lock()
        guard !state.isStopped else {
            state.condition.unlock()
            return false
        }
        state.callbacksInFlight += 1
        state.condition.unlock()

        callback()

        state.condition.lock()
        state.callbacksInFlight -= 1
        if state.callbacksInFlight == 0 {
            state.condition.broadcast()
        }
        let active = !state.isStopped
        state.condition.unlock()
        return active
    }

    private func finishSchemeTask(_ taskID: ObjectIdentifier) {
        stopSchemeTask(taskID)
    }

    private func stopSchemeTask(_ taskID: ObjectIdentifier) {
        lock.lock()
        let state = activeSchemeTasks.removeValue(forKey: taskID)
        lock.unlock()
        guard let state else { return }

        state.condition.lock()
        state.isStopped = true
        while state.callbacksInFlight > 0 {
            state.condition.wait()
        }
        state.condition.unlock()
    }

    private static func fileSize(for url: URL) -> Int {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = values.fileSize else {
            return -1
        }
        return fileSize
    }

    private func isTrustedDiffViewerFileURL(_ url: URL) -> Bool {
        let rootPath = trustedRootURL.path
        return url.isFileURL && url.path.hasPrefix(rootPath + "/")
    }

    private func pruneExpiredSessionsLocked(now: Date) {
        sessions = sessions.filter { _, session in
            now.timeIntervalSince(session.createdAt) <= maxSessionAge
        }
    }

    private func responseHeaders(for file: RegisteredFile) -> [String: String] {
        var headers = [
            "Content-Type": "\(file.mimeType); charset=utf-8",
            "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff",
            "Cross-Origin-Resource-Policy": "same-origin"
        ]
        if file.mimeType == "text/html" {
            headers["Content-Security-Policy"] = [
                "default-src 'none'",
                "script-src 'self' 'unsafe-inline' 'wasm-unsafe-eval'",
                "style-src 'unsafe-inline'",
                "img-src 'self' data:",
                "connect-src 'self'",
                "font-src 'none'",
                "object-src 'none'",
                "base-uri 'none'",
                "form-action 'none'"
            ].joined(separator: "; ")
        }
        return headers
    }
}

