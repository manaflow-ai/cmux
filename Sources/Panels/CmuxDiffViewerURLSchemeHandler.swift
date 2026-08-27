import CmuxBrowser
import Foundation
import WebKit

/// Serves trusted diff-viewer assets while keeping WebKit task lifecycle on the
/// main actor. Background workers may produce response values, but they never
/// retain or invoke a ``WKURLSchemeTask``.
@MainActor
final class CmuxDiffViewerURLSchemeHandler: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "cmux-diff-viewer"
    static let shared = CmuxDiffViewerURLSchemeHandler()
    // Keep this aligned with Native/DiffSidecar's manifest validation limit.
    nonisolated static let maxRegisteredFiles = CmuxDiffViewerSessionPreparer.defaultMaximumRegisteredFiles

    typealias RegisteredFile = CmuxDiffViewerRegisteredFile
    private typealias Session = CmuxDiffViewerPreparedSession
    private typealias ActiveSchemeTask = (
        generation: UUID,
        task: WKURLSchemeTask,
        operation: Task<Void, Never>?
    )
    private typealias ManifestLoad = (
        generation: UUID,
        task: Task<Session?, Never>
    )

    private var sessions: [String: Session] = [:]
    private var activeSchemeTasks: [ObjectIdentifier: ActiveSchemeTask] = [:]
    private var manifestLoads: [String: ManifestLoad] = [:]
    private let assetReader: DiffViewerAssetReader
    private let pickerCommandRunner: DiffViewerPickerCommandRunner
    private let sessionPreparer: CmuxDiffViewerSessionPreparer
    private let maxSessionAge: TimeInterval = 24 * 60 * 60

    override init() {
        assetReader = DiffViewerAssetReader()
        pickerCommandRunner = DiffViewerPickerCommandRunner()
        sessionPreparer = CmuxDiffViewerSessionPreparer()
        super.init()
    }

    init(
        assetReader: DiffViewerAssetReader = DiffViewerAssetReader(),
        pickerCommandRunner: DiffViewerPickerCommandRunner,
        sessionPreparer: CmuxDiffViewerSessionPreparer = CmuxDiffViewerSessionPreparer()
    ) {
        self.assetReader = assetReader
        self.pickerCommandRunner = pickerCommandRunner
        self.sessionPreparer = sessionPreparer
        super.init()
    }

    /// Prepares a caller-supplied allowlist off-main, then installs its value-only session.
    func register(token: String, files: [RegisteredFile], now: Date = Date()) async throws {
        let sessionPreparer = sessionPreparer
        let prepared = try await Task.detached(priority: .userInitiated) {
            try sessionPreparer.prepare(token: token, files: files, now: now)
        }.value
        install(prepared, now: now)
    }

    /// Installs a session that was already validated on a socket worker.
    func install(_ preparedSession: CmuxDiffViewerPreparedSession, now: Date = Date()) {
        pruneExpiredSessions(now: now)
        sessions[preparedSession.token] = preparedSession
    }

    /// Whether the token currently has a registered in-memory session.
    /// Used to trust-gate native bridge calls after a page has begun loading.
    func hasActiveSession(token: String, now: Date = Date()) -> Bool {
        guard Self.isValidToken(token) else { return false }
        pruneExpiredSessions(now: now)
        return sessions[token] != nil
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

        pruneExpiredSessions(now: now)
        return sessions[token]?.registeredFile(forRequestPath: requestPath)
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist))
            return
        }

        let (taskID, generation) = beginSchemeTask(urlSchemeTask)
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.serve(
                requestURL: requestURL,
                taskID: taskID,
                generation: generation
            )
        }
        setSchemeTaskOperation(operation, taskID: taskID, generation: generation)
    }

    /// Restores a missing session asynchronously before routing a WebKit request.
    private func serve(
        requestURL: URL,
        taskID: ObjectIdentifier,
        generation: UUID
    ) async {
        guard requestURL.scheme == Self.scheme,
              let token = requestURL.host,
              Self.isValidToken(token) else {
            failSchemeTask(taskID, generation: generation, code: NSURLErrorBadURL)
            return
        }
        if !hasActiveSession(token: token) {
            guard await registerFromManifest(token: token) else {
                failSchemeTask(taskID, generation: generation, code: NSURLErrorFileDoesNotExist)
                return
            }
        }
        guard isSchemeTaskActive(taskID, generation: generation) else { return }

        // Mirror the HTTP server's picker routes after the token is backed by a
        // validated session. Ordinary file misses remain cache-only; only a
        // successful branch regeneration explicitly reloads its manifest.
        let path = URLComponents(
            url: requestURL,
            resolvingAgainstBaseURL: false
        )?.percentEncodedPath ?? requestURL.path
        if path == "/__cmux_diff_viewer_refs" {
            await handleDiffViewerRefsRoute(
                requestURL: requestURL,
                token: token,
                taskID: taskID,
                generation: generation
            )
            return
        }
        if path == "/__cmux_diff_viewer_branch" {
            await handleDiffViewerBranchRoute(
                requestURL: requestURL,
                token: token,
                taskID: taskID,
                generation: generation
            )
            return
        }

        guard let file = registeredFile(for: requestURL) else {
            failSchemeTask(taskID, generation: generation, code: NSURLErrorFileDoesNotExist)
            return
        }
        await streamFile(
            file,
            requestURL: requestURL,
            taskID: taskID,
            generation: generation
        )
    }

    private static func diffViewerQueryItems(from url: URL) -> [String: String] {
        var result: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            if result[item.name] == nil {
                result[item.name] = item.value ?? ""
            }
        }
        return result
    }

    private func handleDiffViewerRefsRoute(
        requestURL: URL,
        token: String,
        taskID: ObjectIdentifier,
        generation: UUID
    ) async {
        let query = Self.diffViewerQueryItems(from: requestURL)
        guard let repo = query["repo"], !repo.isEmpty else {
            failSchemeTask(taskID, generation: generation, code: NSURLErrorBadURL)
            return
        }

        // Thread the request token so the CLI binds refs enumeration to a
        // session that actually owns this repo.
        var arguments = ["__diff-viewer-refs", "--repo", repo, "--token", token]
        if let base = query["base"], !base.isEmpty {
            arguments += ["--base", base]
        }
        let pickerCommandRunner = pickerCommandRunner
        let stdout = await pickerCommandRunner.run(arguments: arguments)
        guard !Task.isCancelled else { return }
        guard let stdout else {
            failSchemeTask(
                taskID,
                generation: generation,
                code: NSURLErrorCannotConnectToHost
            )
            return
        }
        respondScheme(
            taskID: taskID,
            generation: generation,
            requestURL: requestURL,
            statusCode: 200,
            headers: [
                "Content-Type": "application/json; charset=utf-8",
                "Cache-Control": "no-store",
                "X-Content-Type-Options": "nosniff",
                "Cross-Origin-Resource-Policy": "same-origin"
            ],
            body: Data(stdout.utf8)
        )
    }

    private func handleDiffViewerBranchRoute(
        requestURL: URL,
        token: String,
        taskID: ObjectIdentifier,
        generation: UUID
    ) async {
        let query = Self.diffViewerQueryItems(from: requestURL)
        guard let group = query["group"], !group.isEmpty,
              let repo = query["repo"], !repo.isEmpty,
              let base = query["base"], !base.isEmpty else {
            failSchemeTask(taskID, generation: generation, code: NSURLErrorBadURL)
            return
        }

        // Thread the request token so the CLI binds regeneration to the session
        // that owns this group. Only value data crosses to the subprocess actor.
        let arguments = [
            "__diff-viewer-branch", "--group", group,
            "--repo", repo, "--base", base, "--token", token
        ]
        let pickerCommandRunner = pickerCommandRunner
        let stdout = await pickerCommandRunner.run(arguments: arguments)
        guard !Task.isCancelled else { return }
        guard let viewerURLString = stdout?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !viewerURLString.isEmpty else {
            failSchemeTask(
                taskID,
                generation: generation,
                code: NSURLErrorCannotConnectToHost
            )
            return
        }
        // Defense in depth: the produced viewer URL must be a custom-scheme URL
        // for this request's token and a file in the freshly written manifest.
        guard let viewerURL = URL(string: viewerURLString),
              viewerURL.scheme == Self.scheme,
              viewerURL.host == token,
              await registerFromManifest(token: token),
              registeredFile(for: viewerURL) != nil else {
            failSchemeTask(
                taskID,
                generation: generation,
                code: NSURLErrorBadServerResponse
            )
            return
        }

        // WKURLSchemeTask cannot drive a top-level 302 the browser follows, so
        // return a tiny CSP-constrained document that navigates in place.
        let metaEscaped = Self.htmlAttributeEscaped(viewerURLString)
        let jsEscaped = viewerURLString
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "<", with: "\\u003C")
        let html = """
        <!doctype html><html><head><meta charset="utf-8">\
        <meta http-equiv="refresh" content="0;url=\(metaEscaped)"></head>\
        <body><script>window.location.replace("\(jsEscaped)");</script></body></html>
        """
        respondScheme(
            taskID: taskID,
            generation: generation,
            requestURL: requestURL,
            statusCode: 200,
            headers: [
                "Content-Type": "text/html; charset=utf-8",
                "Cache-Control": "no-store",
                "X-Content-Type-Options": "nosniff",
                "Cross-Origin-Resource-Policy": "same-origin",
                "Content-Security-Policy": [
                    "default-src 'none'",
                    "script-src 'unsafe-inline'",
                    "base-uri 'none'",
                    "form-action 'none'"
                ].joined(separator: "; ")
            ],
            body: Data(html.utf8)
        )
    }

    /// Responds to a registered scheme task on the main actor. A stale
    /// generation or a task WebKit already stopped makes the response a no-op.
    private func respondScheme(
        taskID: ObjectIdentifier,
        generation: UUID,
        requestURL: URL,
        statusCode: Int,
        headers: [String: String],
        body: Data
    ) {
        var responseHeaders = headers
        responseHeaders["Content-Length"] = "\(body.count)"
        let response = HTTPURLResponse(
            url: requestURL,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: responseHeaders
        ) ?? URLResponse(url: requestURL, mimeType: headers["Content-Type"], expectedContentLength: body.count, textEncodingName: "utf-8")

        guard performSchemeTaskCallback(taskID, generation: generation, { $0.didReceive(response) }) else {
            return
        }
        guard performSchemeTaskCallback(taskID, generation: generation, { $0.didReceive(body) }) else {
            return
        }
        guard performSchemeTaskCallback(taskID, generation: generation, { $0.didFinish() }) else {
            return
        }
        finishSchemeTask(taskID, generation: generation)
    }

    /// Fails a registered scheme task on the main actor, unless WebKit already
    /// stopped it or the object identifier has since been reused.
    private func failSchemeTask(
        _ taskID: ObjectIdentifier,
        generation: UUID,
        code: Int
    ) {
        _ = performSchemeTaskCallback(taskID, generation: generation, {
            $0.didFailWithError(NSError(domain: NSURLErrorDomain, code: code))
        })
        finishSchemeTask(taskID, generation: generation)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        let taskID = ObjectIdentifier(urlSchemeTask as AnyObject)
        stopSchemeTask(taskID)
    }

    nonisolated static func registeredFile(from object: [String: Any]) -> RegisteredFile? {
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

    /// Re-registers a token from its bounded on-disk manifest without blocking the main actor.
    ///
    /// Concurrent requests for the same missing token share one detached load. The
    /// prepared session is installed only after all JSON, path, file, and lease
    /// validation has completed.
    func registerFromManifest(token: String, now: Date = Date()) async -> Bool {
        guard Self.isValidToken(token) else { return false }
        let load: ManifestLoad
        if let existing = manifestLoads[token] {
            load = existing
        } else {
            let generation = UUID()
            let sessionPreparer = sessionPreparer
            let task = Task.detached(priority: .userInitiated) {
                try? sessionPreparer.prepareFromManifest(token: token, now: now)
            }
            load = (generation: generation, task: task)
            manifestLoads[token] = load
        }

        let preparedSession = await load.task.value
        if manifestLoads[token]?.generation == load.generation {
            manifestLoads.removeValue(forKey: token)
        }
        guard let preparedSession else { return false }
        install(preparedSession, now: now)
        return true
    }

    /// Whether a diff viewer surface can be restored through the custom scheme.
    /// Requires a local-only manifest and an entry page that is neither a
    /// pending placeholder nor a redirect stub. Pending pages poll a
    /// deferred-load wait endpoint, and redirect pages bounce to the original
    /// `http://127.0.0.1:<port>` URL; both only work against the local HTTP
    /// server, which is gone after restart, so they would fail under the
    /// custom scheme. This is a cache-only query; preparation classifies each
    /// HTML entry off-main before the session is installed.
    func diffViewerRestorable(token: String, requestPath: String) -> Bool {
        guard Self.isValidToken(token), Self.isValidRequestPath(requestPath) else { return false }
        pruneExpiredSessions(now: Date())
        return sessions[token]?.isRestorable(requestPath: requestPath) == true
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

    /// Escapes a string for safe interpolation into a double-quoted HTML
    /// attribute value (the meta-refresh `content` here). Covers the five XML
    /// significant characters so a stray quote cannot break out of the attribute.
    static func htmlAttributeEscaped(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            default: result.append(character)
            }
        }
        return result
    }

    nonisolated static func isValidToken(_ token: String) -> Bool {
        CmuxDiffViewerSessionPreparer.isValidToken(token)
    }

    nonisolated static func isValidRequestPath(_ path: String) -> Bool {
        CmuxDiffViewerSessionPreparer.isValidRequestPath(path)
    }

    static func requestPath(for url: URL) -> String? {
        let rawPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        let requestPath = rawPath.isEmpty ? "/" : rawPath
        guard isValidRequestPath(requestPath) else { return nil }
        return requestPath
    }

    /// Streams one prepared file while keeping every WebKit callback on the main actor.
    private func streamFile(
        _ file: RegisteredFile,
        requestURL: URL,
        taskID: ObjectIdentifier,
        generation: UUID
    ) async {
        let response = HTTPURLResponse(
            url: requestURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: responseHeaders(for: file)
        ) ?? URLResponse(
            url: requestURL,
            mimeType: file.mimeType,
            expectedContentLength: file.fileSize ?? -1,
            textEncodingName: "utf-8"
        )
        let assetReader = assetReader
        do {
            guard performSchemeTaskCallback(taskID, generation: generation, {
                $0.didReceive(response)
            }) else {
                await assetReader.close(streamID: generation)
                return
            }

            while isSchemeTaskActive(taskID, generation: generation) {
                try Task.checkCancellation()
                let data = try await assetReader.read(
                    streamID: generation,
                    fileURL: file.fileURL,
                    upToCount: 64 * 1024
                )
                guard isSchemeTaskActive(taskID, generation: generation) else {
                    await assetReader.close(streamID: generation)
                    return
                }
                if data.isEmpty {
                    break
                }
                guard performSchemeTaskCallback(taskID, generation: generation, {
                    $0.didReceive(data)
                }) else {
                    await assetReader.close(streamID: generation)
                    return
                }
            }

            await assetReader.close(streamID: generation)
            guard performSchemeTaskCallback(taskID, generation: generation, {
                $0.didFinish()
            }) else { return }
            finishSchemeTask(taskID, generation: generation)
        } catch is CancellationError {
            await assetReader.close(streamID: generation)
        } catch {
            await assetReader.close(streamID: generation)
            if isSchemeTaskActive(taskID, generation: generation) {
                failSchemeTask(taskID, generation: generation, error: error)
            }
        }
    }

    private func beginSchemeTask(_ urlSchemeTask: WKURLSchemeTask) -> (ObjectIdentifier, UUID) {
        let taskID = ObjectIdentifier(urlSchemeTask as AnyObject)
        let generation = UUID()
        let replaced = activeSchemeTasks.updateValue(
            (generation: generation, task: urlSchemeTask, operation: nil),
            forKey: taskID
        )
        replaced?.operation?.cancel()
        return (taskID, generation)
    }

    private func setSchemeTaskOperation(
        _ operation: Task<Void, Never>,
        taskID: ObjectIdentifier,
        generation: UUID
    ) {
        guard var state = activeSchemeTasks[taskID], state.generation == generation else {
            operation.cancel()
            return
        }
        state.operation = operation
        activeSchemeTasks[taskID] = state
    }

    private func isSchemeTaskActive(_ taskID: ObjectIdentifier, generation: UUID) -> Bool {
        activeSchemeTasks[taskID]?.generation == generation
    }

    private func performSchemeTaskCallback(
        _ taskID: ObjectIdentifier,
        generation: UUID,
        _ callback: (WKURLSchemeTask) -> Void
    ) -> Bool {
        guard let state = activeSchemeTasks[taskID], state.generation == generation else {
            return false
        }
        callback(state.task)
        return isSchemeTaskActive(taskID, generation: generation)
    }

    private func failSchemeTask(
        _ taskID: ObjectIdentifier,
        generation: UUID,
        error: Error
    ) {
        _ = performSchemeTaskCallback(taskID, generation: generation, {
            $0.didFailWithError(error)
        })
        finishSchemeTask(taskID, generation: generation)
    }

    private func finishSchemeTask(_ taskID: ObjectIdentifier, generation: UUID) {
        guard activeSchemeTasks[taskID]?.generation == generation else { return }
        activeSchemeTasks.removeValue(forKey: taskID)
    }

    private func stopSchemeTask(_ taskID: ObjectIdentifier) {
        let state = activeSchemeTasks.removeValue(forKey: taskID)
        state?.operation?.cancel()
    }

    private func pruneExpiredSessions(now: Date) {
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
