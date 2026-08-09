import Darwin
import Foundation
import WebKit

/// Serves trusted diff-viewer assets while keeping WebKit task lifecycle on the
/// main actor. Background workers may produce response values, but they never
/// retain or invoke a ``WKURLSchemeTask``.
@MainActor
final class CmuxDiffViewerURLSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "cmux-diff-viewer"
    static let shared = CmuxDiffViewerURLSchemeHandler()
    static let maxRegisteredFiles = 1024

    typealias RegisteredFile = CmuxDiffViewerRegisteredFile
    private typealias Session = (
        filesByPath: [String: RegisteredFile],
        createdAt: Date,
        lease: CmuxDiffViewerSessionLease
    )
    private typealias ActiveSchemeTask = (
        generation: UUID,
        task: WKURLSchemeTask,
        operation: Task<Void, Never>?
    )

    private var sessions: [String: Session] = [:]
    private var activeSchemeTasks: [ObjectIdentifier: ActiveSchemeTask] = [:]
    private let assetReader = DiffViewerAssetReader()
    // Branch picker routes shell out to the bundled CLI (git). Run them on a
    // dedicated concurrent queue so a slow/hung git invocation cannot stall
    // restored diff-viewer file serving. The queue returns values to the main
    // actor and never touches a WKURLSchemeTask directly.
    private let pickerQueue = DispatchQueue(
        label: "com.manaflow.cmux.diff-viewer-picker",
        qos: .userInitiated,
        attributes: .concurrent
    )
    // Hard cap on a single bundled-CLI picker invocation before it is terminated.
    private let pickerCommandTimeout: TimeInterval = 15
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
        guard files.count <= Self.maxRegisteredFiles else {
            throw NSError(domain: "CmuxDiffViewerURLSchemeHandler", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "Diff viewer allowlist is too large"
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

        let lease = try CmuxDiffViewerSessionLease(root: trustedRootURL, token: token)
        pruneExpiredSessions(now: now)
        sessions[token] = (filesByPath: byPath, createdAt: now, lease: lease)
    }

    /// Whether the token currently has a registered (or manifest-restorable)
    /// session. Used to trust-gate native bridge calls from diff viewer pages.
    func hasActiveSession(token: String, now: Date = Date()) -> Bool {
        guard Self.isValidToken(token) else { return false }
        pruneExpiredSessions(now: now)
        let isRegistered = sessions[token] != nil
        if isRegistered {
            return true
        }
        return registerFromManifest(token: token, now: now)
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
        let hasSession = sessions[token] != nil
        let file = sessions[token]?.filesByPath[requestPath]
        if let file {
            return file
        }

        // Miss on an active session: the on-disk manifest may have grown
        // out-of-band since the session was cached. The branch picker's
        // regenerate route runs the bundled CLI in a CHILD process, which writes
        // the new page and appends it to `.manifest-<token>.json` without
        // updating this handler's in-memory allowlist; the redirect then targets
        // a path this cache has never seen. Reload the manifest from disk once
        // and retry so freshly regenerated pages resolve instead of 404ing.
        guard hasSession, registerFromManifest(token: token, now: now) else {
            return nil
        }
        return sessions[token]?.filesByPath[requestPath]
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist))
            return
        }

        // Mirror the HTTP server's branch picker routes so the picker works when
        // a diff viewer surface is restored under the custom scheme (the local
        // HTTP server is gone after an app restart). The token (request host)
        // must have an active session before we run any git command.
        if requestURL.scheme == Self.scheme,
           let token = requestURL.host,
           Self.isValidToken(token),
           hasActiveSession(token: token) {
            let path = (URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? requestURL.path)
            if path == "/__cmux_diff_viewer_refs" {
                handleDiffViewerRefsRoute(requestURL: requestURL, token: token, urlSchemeTask: urlSchemeTask)
                return
            }
            if path == "/__cmux_diff_viewer_branch" {
                handleDiffViewerBranchRoute(requestURL: requestURL, token: token, urlSchemeTask: urlSchemeTask)
                return
            }
        }

        guard let file = registeredFile(for: requestURL) else {
            urlSchemeTask.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist))
            return
        }

        startStreamingFile(file, requestURL: requestURL, urlSchemeTask: urlSchemeTask)
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

    /// Path to the bundled `cmux` CLI used to run the headless picker commands.
    nonisolated private static func bundledCLIURL() -> URL? {
        if let env = ProcessInfo.processInfo.environment["CMUX_BUNDLED_CLI_PATH"],
           !env.isEmpty,
           FileManager.default.isExecutableFile(atPath: env) {
            return URL(fileURLWithPath: env)
        }
        let candidate = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/bin/cmux", isDirectory: false)
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        return nil
    }

    /// Runs the bundled CLI with a hard timeout. The child is terminated (then
    /// killed) if it exceeds `pickerCommandTimeout`, so a hung git invocation
    /// cannot block the caller indefinitely. stdout goes to a private temporary
    /// file so the child can never block on a full pipe. Returns nil on launch
    /// failure.
    nonisolated private static func runBundledDiffViewerCommand(
        _ arguments: [String],
        timeout: TimeInterval
    ) -> (status: Int32, stdout: Data)? {
        guard let cli = bundledCLIURL() else { return nil }
        let process = Process()
        process.executableURL = cli
        process.arguments = arguments
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-diff-viewer-picker-\(UUID().uuidString).out")
        guard FileManager.default.createFile(
            atPath: outputURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ), let outputHandle = try? FileHandle(forWritingTo: outputURL) else {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: outputURL) }

        process.standardOutput = outputHandle
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            try? outputHandle.close()
            return nil
        }

        let deadlineQueue = DispatchQueue(
            label: "com.manaflow.cmux.diff-viewer-picker-deadline",
            qos: .userInitiated
        )
        // One-shot dispatch timers enforce genuine Process deadlines from this
        // synchronous legacy seam, which has no async Task to host Clock.sleep.
        let terminateTimer = DispatchSource.makeTimerSource(queue: deadlineQueue)
        terminateTimer.schedule(deadline: .now() + timeout)
        terminateTimer.setEventHandler {
            if process.isRunning {
                process.terminate()
            }
        }
        let killTimer = DispatchSource.makeTimerSource(queue: deadlineQueue)
        killTimer.schedule(deadline: .now() + timeout + 2)
        killTimer.setEventHandler {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        terminateTimer.resume()
        killTimer.resume()

        process.waitUntilExit()
        terminateTimer.cancel()
        killTimer.cancel()
        try? outputHandle.close()
        guard let output = try? Data(contentsOf: outputURL) else { return nil }
        return (process.terminationStatus, output)
    }

    private func handleDiffViewerRefsRoute(
        requestURL: URL,
        token: String,
        urlSchemeTask: WKURLSchemeTask
    ) {
        let (taskID, generation) = beginSchemeTask(urlSchemeTask)
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
        let commandArguments = arguments
        let timeout = pickerCommandTimeout
        pickerQueue.async { [weak self] in
            let result = Self.runBundledDiffViewerCommand(commandArguments, timeout: timeout)
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let result, result.status == 0 else {
                    self.failSchemeTask(
                        taskID,
                        generation: generation,
                        code: NSURLErrorCannotConnectToHost
                    )
                    return
                }
                self.respondScheme(
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
                    body: result.stdout
                )
            }
        }
    }

    private func handleDiffViewerBranchRoute(
        requestURL: URL,
        token: String,
        urlSchemeTask: WKURLSchemeTask
    ) {
        let (taskID, generation) = beginSchemeTask(urlSchemeTask)
        let query = Self.diffViewerQueryItems(from: requestURL)
        guard let group = query["group"], !group.isEmpty,
              let repo = query["repo"], !repo.isEmpty,
              let base = query["base"], !base.isEmpty else {
            failSchemeTask(taskID, generation: generation, code: NSURLErrorBadURL)
            return
        }

        // Thread the request token so the CLI binds regeneration to the session
        // that owns this group. Only value data crosses to the picker queue.
        let arguments = [
            "__diff-viewer-branch", "--group", group,
            "--repo", repo, "--base", base, "--token", token
        ]
        let timeout = pickerCommandTimeout
        pickerQueue.async { [weak self] in
            let result = Self.runBundledDiffViewerCommand(arguments, timeout: timeout)
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let result, result.status == 0,
                      let viewerURLString = String(data: result.stdout, encoding: .utf8)?
                          .trimmingCharacters(in: .whitespacesAndNewlines),
                      !viewerURLString.isEmpty else {
                    self.failSchemeTask(
                        taskID,
                        generation: generation,
                        code: NSURLErrorCannotConnectToHost
                    )
                    return
                }
                // Defense in depth: the produced viewer URL must be a
                // custom-scheme URL for this request's token.
                guard let viewerURL = URL(string: viewerURLString),
                      viewerURL.scheme == Self.scheme,
                      viewerURL.host == token else {
                    self.failSchemeTask(
                        taskID,
                        generation: generation,
                        code: NSURLErrorBadServerResponse
                    )
                    return
                }

                // WKURLSchemeTask cannot drive a top-level 302 the browser
                // follows, so return a tiny document that navigates in place.
                let metaEscaped = Self.htmlAttributeEscaped(viewerURLString)
                let jsEscaped = viewerURLString
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                let html = """
                <!doctype html><html><head><meta charset="utf-8">\
                <meta http-equiv="refresh" content="0;url=\(metaEscaped)"></head>\
                <body><script>window.location.replace("\(jsEscaped)");</script></body></html>
                """
                self.respondScheme(
                    taskID: taskID,
                    generation: generation,
                    requestURL: requestURL,
                    statusCode: 200,
                    headers: [
                        "Content-Type": "text/html; charset=utf-8",
                        "Cache-Control": "no-store",
                        "X-Content-Type-Options": "nosniff",
                        "Cross-Origin-Resource-Policy": "same-origin"
                    ],
                    body: Data(html.utf8)
                )
            }
        }
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
        let (taskID, generation) = beginSchemeTask(urlSchemeTask)
        let response = HTTPURLResponse(
            url: requestURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: responseHeaders(for: file)
        ) ?? URLResponse(
            url: requestURL,
            mimeType: file.mimeType,
            expectedContentLength: Self.fileSize(for: file.fileURL),
            textEncodingName: "utf-8"
        )
        let assetReader = assetReader

        let operation = Task { @MainActor [weak self] in
            guard let self else {
                await assetReader.close(streamID: generation)
                return
            }
            do {
                guard self.performSchemeTaskCallback(taskID, generation: generation, {
                    $0.didReceive(response)
                }) else {
                    await assetReader.close(streamID: generation)
                    return
                }

                while self.isSchemeTaskActive(taskID, generation: generation) {
                    try Task.checkCancellation()
                    let data = try await assetReader.read(
                        streamID: generation,
                        fileURL: file.fileURL,
                        upToCount: 64 * 1024
                    )
                    guard self.isSchemeTaskActive(taskID, generation: generation) else {
                        await assetReader.close(streamID: generation)
                        return
                    }
                    if data.isEmpty {
                        break
                    }
                    guard self.performSchemeTaskCallback(taskID, generation: generation, {
                        $0.didReceive(data)
                    }) else {
                        await assetReader.close(streamID: generation)
                        return
                    }
                }

                await assetReader.close(streamID: generation)
                guard self.performSchemeTaskCallback(taskID, generation: generation, {
                    $0.didFinish()
                }) else { return }
                self.finishSchemeTask(taskID, generation: generation)
            } catch is CancellationError {
                await assetReader.close(streamID: generation)
            } catch {
                await assetReader.close(streamID: generation)
                self.failSchemeTask(taskID, generation: generation, error: error)
            }
        }
        setSchemeTaskOperation(operation, taskID: taskID, generation: generation)
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
