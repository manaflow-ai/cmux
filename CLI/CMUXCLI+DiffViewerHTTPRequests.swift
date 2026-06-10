import Darwin
import Foundation


// MARK: - Diff Viewer HTTP Request Handling
extension CMUXCLI {
    func handleDiffViewerHTTPConnection(
        fileDescriptor fd: Int32,
        port: Int,
        manifestCache: DiffViewerHTTPManifestCache
    ) {
        defer { close(fd) }

        do {
            guard let request = try readDiffViewerHTTPRequest(fileDescriptor: fd) else {
                return
            }
            guard request.method == "GET" || request.method == "HEAD" else {
                try sendDiffViewerHTTPResponse(
                    fileDescriptor: fd,
                    status: 405,
                    reason: "Method Not Allowed",
                    headers: ["Allow": "GET, HEAD"],
                    body: Data("405 Method Not Allowed\n".utf8),
                    omitBody: request.method == "HEAD"
                )
                return
            }

            if request.path == "/__cmux_diff_viewer_healthz" {
                try sendDiffViewerHTTPResponse(
                    fileDescriptor: fd,
                    status: 200,
                    reason: "OK",
                    headers: ["Content-Type": "text/plain; charset=utf-8"],
                    body: Self.diffViewerHTTPServerHealthResponse,
                    omitBody: request.method == "HEAD"
                )
                return
            }

            if request.path.hasPrefix("/__cmux_diff_viewer_wait/") {
                try sendDiffViewerHTTPWaitForReplacement(
                    requestPath: request.path,
                    fileDescriptor: fd,
                    port: port,
                    manifestCache: manifestCache,
                    omitBody: request.method == "HEAD"
                )
                return
            }

            guard let file = try diffViewerHTTPAllowedFile(
                requestPath: request.path,
                manifestCache: manifestCache
            ) else {
                try sendDiffViewerHTTPNotFound(fileDescriptor: fd, omitBody: request.method == "HEAD")
                return
            }

            try sendDiffViewerHTTPFile(
                file,
                fileDescriptor: fd,
                port: port,
                omitBody: request.method == "HEAD"
            )
        } catch {
            try? sendDiffViewerHTTPResponse(
                fileDescriptor: fd,
                status: 500,
                reason: "Internal Server Error",
                headers: ["Content-Type": "text/plain; charset=utf-8"],
                body: Data("500 Internal Server Error\n".utf8),
                omitBody: false
            )
        }
    }

    private struct DiffViewerHTTPRequest {
        var method: String
        var path: String
    }

    private func readDiffViewerHTTPRequest(fileDescriptor fd: Int32) throws -> DiffViewerHTTPRequest? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        let headerEnd = Data("\r\n\r\n".utf8)

        while data.count < 16 * 1024 {
            let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                return recv(fd, baseAddress, rawBuffer.count, 0)
            }
            if count == 0 {
                return nil
            }
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                throw CLIError(message: "Failed to read diff viewer request: \(posixErrorMessage(errno))")
            }
            buffer.withUnsafeBufferPointer { pointer in
                if let baseAddress = pointer.baseAddress {
                    data.append(baseAddress, count: count)
                }
            }
            if data.range(of: headerEnd) != nil {
                break
            }
        }

        guard let header = String(data: data, encoding: .utf8),
              let firstLine = header.components(separatedBy: "\r\n").first else {
            throw CLIError(message: "Invalid diff viewer request")
        }
        let parts = firstLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            throw CLIError(message: "Invalid diff viewer request")
        }

        let method = String(parts[0]).uppercased()
        var target = String(parts[1])
        if target.hasPrefix("http://") || target.hasPrefix("https://") {
            guard let components = URLComponents(string: target) else {
                throw CLIError(message: "Invalid diff viewer request target")
            }
            target = components.percentEncodedPath
        }
        if let queryIndex = target.firstIndex(of: "?") {
            target = String(target[..<queryIndex])
        }
        guard target.hasPrefix("/") else {
            throw CLIError(message: "Invalid diff viewer request path")
        }
        return DiffViewerHTTPRequest(method: method, path: target)
    }

    private func diffViewerHTTPAllowedFile(
        requestPath rawPath: String,
        manifestCache: DiffViewerHTTPManifestCache
    ) throws -> DiffViewerAllowedFile? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let withoutLeadingSlash = String(trimmed.dropFirst())
        guard let separator = withoutLeadingSlash.firstIndex(of: "/") else {
            return nil
        }

        let token = String(withoutLeadingSlash[..<separator])
        let requestPath = "/" + String(withoutLeadingSlash[withoutLeadingSlash.index(after: separator)...])
        guard diffViewerHTTPIsValidToken(token),
              diffViewerHTTPIsValidRequestPath(requestPath) else {
            return nil
        }
        return try manifestCache.file(token: token, requestPath: requestPath)
    }

    private func sendDiffViewerHTTPWaitForReplacement(
        requestPath rawPath: String,
        fileDescriptor fd: Int32,
        port: Int,
        manifestCache: DiffViewerHTTPManifestCache,
        omitBody: Bool
    ) throws {
        let prefix = "/__cmux_diff_viewer_wait/"
        guard rawPath.hasPrefix(prefix) else {
            try sendDiffViewerHTTPNotFound(fileDescriptor: fd, omitBody: omitBody)
            return
        }

        let targetPath = "/" + String(rawPath.dropFirst(prefix.count))
        guard let file = try diffViewerHTTPAllowedFile(
            requestPath: targetPath,
            manifestCache: manifestCache
        ), file.mimeType == "text/html" else {
            try sendDiffViewerHTTPNotFound(fileDescriptor: fd, omitBody: omitBody)
            return
        }

        guard waitForDiffViewerHTTPReplacement(file) else {
            try sendDiffViewerHTTPWaitTimedOut(fileDescriptor: fd, omitBody: omitBody)
            return
        }
        try sendDiffViewerHTTPFile(
            file,
            fileDescriptor: fd,
            port: port,
            omitBody: omitBody
        )
    }

    func loadDiffViewerHTTPManifestFiles(
        token: String,
        rootDirectory: URL
    ) throws -> [String: DiffViewerAllowedFile] {
        let url = diffViewerHTTPManifestURL(token: token, rootDirectory: rootDirectory)
        let manifest = try JSONDecoder().decode(DiffViewerHTTPManifest.self, from: Data(contentsOf: url))
        guard manifest.token == token,
              !manifest.files.isEmpty,
              manifest.files.count <= 4096 else {
            throw CLIError(message: "Invalid diff viewer manifest")
        }

        let rootPath = rootDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        var files: [String: DiffViewerAllowedFile] = [:]
        for file in manifest.files {
            guard diffViewerHTTPIsValidRequestPath(file.requestPath),
                  diffViewerHTTPIsAllowedMimeType(file.mimeType),
                  diffViewerHTTPPathExtensionMatchesMimeType(path: file.requestPath, mimeType: file.mimeType) else {
                throw CLIError(message: "Invalid diff viewer manifest entry")
            }
            if let remoteURLString = file.remoteURL {
                guard file.mimeType == "text/x-diff",
                      file.filePath.isEmpty,
                      let remoteURL = URL(string: remoteURLString),
                      diffViewerHTTPIsAllowedRemotePatchURL(remoteURL),
                      files[file.requestPath] == nil else {
                    throw CLIError(message: "Invalid diff viewer remote manifest entry")
                }
                var normalizedFile = file
                normalizedFile.remoteURL = remoteURL.absoluteString
                files[file.requestPath] = normalizedFile
                continue
            }
            let fileURL = URL(fileURLWithPath: file.filePath, isDirectory: false)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            guard fileURL.path.hasPrefix(rootPath + "/") else {
                throw CLIError(message: "Diff viewer manifest file is outside the viewer directory")
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  FileManager.default.isReadableFile(atPath: fileURL.path),
                  files[file.requestPath] == nil else {
                throw CLIError(message: "Invalid diff viewer manifest file")
            }

            var normalizedFile = file
            normalizedFile.filePath = fileURL.path
            files[file.requestPath] = normalizedFile
        }
        return files
    }

    private func diffViewerHTTPIsAllowedRemotePatchURL(_ url: URL) -> Bool {
        guard let canonicalURL = diffInputTrustedRemotePatchURL(url.absoluteString),
              canonicalURL.scheme == "https",
              canonicalURL.host?.lowercased() == "github.com",
              canonicalURL.path == url.path,
              canonicalURL.query == nil,
              canonicalURL.fragment == nil,
              url.query == nil,
              url.fragment == nil else {
            return false
        }
        return canonicalURL.absoluteString == url.absoluteString
    }

    private func waitForDiffViewerHTTPReplacement(_ file: DiffViewerAllowedFile) -> Bool {
        let fileURL = URL(fileURLWithPath: file.filePath, isDirectory: false)
        guard diffViewerHTTPFileIsPending(fileURL) else { return true }

        let fd = open(fileURL.path, O_EVTONLY)
        guard fd >= 0 else { return false }

        let event = DispatchSemaphore(value: 0)
        let cleanup = DispatchSemaphore(value: 0)
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: DispatchQueue.global(qos: .userInitiated)
        )
        source.setEventHandler {
            event.signal()
        }
        source.setCancelHandler {
            close(fd)
            cleanup.signal()
        }
        source.resume()
        defer {
            source.cancel()
            _ = cleanup.wait(timeout: .now() + 1)
        }
        let deadline = Date().addingTimeInterval(diffViewerHTTPReplacementWaitTimeout())
        while diffViewerHTTPFileIsPending(fileURL) {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return false }
            let waitMilliseconds = max(1, Int((min(remaining, 1.0) * 1000).rounded(.up)))
            _ = event.wait(timeout: .now() + .milliseconds(waitMilliseconds))
        }
        return true
    }

    private func diffViewerHTTPReplacementWaitTimeout() -> TimeInterval {
        let defaultTimeout: TimeInterval = 120
        let key = "CMUX_DIFF_VIEWER_WAIT_TIMEOUT_SECONDS"
        guard let raw = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let value = TimeInterval(raw),
              value.isFinite else {
            return defaultTimeout
        }
        return min(max(value, 0.05), 600)
    }

    private func sendDiffViewerHTTPWaitTimedOut(fileDescriptor fd: Int32, omitBody: Bool) throws {
        let title = CMUXDiffViewerLocalization.string(
            "diffViewer.loadingDiff",
            defaultValue: "Loading diff..."
        )
        let message = CMUXDiffViewerLocalization.string(
            "diffViewer.renderFailed",
            defaultValue: "Could not render this diff. Check the patch input and try again."
        )
        let body = Data(diffViewerHTTPStatusHTML(title: title, message: message).utf8)
        try sendDiffViewerHTTPResponse(
            fileDescriptor: fd,
            status: 504,
            reason: "Gateway Timeout",
            headers: ["Content-Type": "text/html; charset=utf-8"],
            body: body,
            omitBody: omitBody
        )
    }

    private func diffViewerHTTPStatusHTML(title: String, message: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(htmlEscaped(title))</title>
          <style>
            :root { color-scheme: light dark; }
            body {
              margin: 0;
              min-height: 100vh;
              display: grid;
              place-items: center;
              background: Canvas;
              color: CanvasText;
              font: 13px -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", Arial, sans-serif;
            }
            main {
              display: grid;
              gap: 10px;
              padding: 24px;
              max-width: 520px;
            }
            h1 {
              margin: 0;
              font-size: 14px;
              font-weight: 600;
            }
            p {
              margin: 0;
              opacity: 0.72;
              line-height: 1.45;
            }
          </style>
        </head>
        <body>
          <main>
            <h1>\(htmlEscaped(title))</h1>
            <p>\(htmlEscaped(message))</p>
          </main>
        </body>
        </html>
        """
    }

    private func diffViewerHTTPFileIsPending(_ fileURL: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return false
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 8192),
              !data.isEmpty,
              let text = String(data: data, encoding: .utf8) else {
            return false
        }
        return text.contains("data-cmux-diff-pending=\"true\"")
    }

    private func sendDiffViewerHTTPFile(
        _ file: DiffViewerAllowedFile,
        fileDescriptor fd: Int32,
        port: Int,
        omitBody: Bool
    ) throws {
        if let remoteURLString = file.remoteURL,
           let remoteURL = URL(string: remoteURLString),
           diffViewerHTTPIsAllowedRemotePatchURL(remoteURL) {
            try sendDiffViewerHTTPRemotePatch(
                remoteURL,
                fileDescriptor: fd,
                port: port,
                omitBody: omitBody
            )
            return
        }

        let fileURL = URL(fileURLWithPath: file.filePath, isDirectory: false)
        var info = stat()
        guard stat(fileURL.path, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            try sendDiffViewerHTTPNotFound(fileDescriptor: fd, omitBody: omitBody)
            return
        }

        var headers = diffViewerHTTPBaseHeaders(port: port)
        headers["Content-Type"] = diffViewerHTTPContentType(file.mimeType)
        headers["Content-Length"] = "\(info.st_size)"
        try sendDiffViewerHTTPHeader(
            fileDescriptor: fd,
            status: 200,
            reason: "OK",
            headers: headers
        )
        guard !omitBody else { return }

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        while true {
            let data = try handle.read(upToCount: 64 * 1024) ?? Data()
            if data.isEmpty {
                break
            }
            try sendAllDiffViewerHTTPData(data, fileDescriptor: fd)
        }
    }

    private func sendDiffViewerHTTPRemotePatch(
        _ remoteURL: URL,
        fileDescriptor fd: Int32,
        port: Int,
        omitBody: Bool
    ) throws {
        var headers = diffViewerHTTPBaseHeaders(port: port)
        headers["Content-Type"] = diffViewerHTTPContentType("text/x-diff")
        headers["X-CMUX-Diff-Viewer-Remote"] = "github"

        if omitBody {
            try sendDiffViewerHTTPHeader(
                fileDescriptor: fd,
                status: 200,
                reason: "OK",
                headers: headers
            )
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "curl",
            "-fL",
            "--silent",
            "--show-error",
            "--max-time", "120",
            remoteURL.absoluteString
        ]
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            try sendDiffViewerHTTPResponse(
                fileDescriptor: fd,
                status: 502,
                reason: "Bad Gateway",
                headers: ["Content-Type": "text/plain; charset=utf-8"],
                body: Data("502 Bad Gateway\n".utf8),
                omitBody: false
            )
            return
        }

        defer {
            if process.isRunning {
                process.terminate()
            }
        }

        let handle = stdoutPipe.fileHandleForReading
        let firstChunk = try handle.read(upToCount: 64 * 1024) ?? Data()
        if firstChunk.isEmpty {
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                try sendDiffViewerHTTPResponse(
                    fileDescriptor: fd,
                    status: 502,
                    reason: "Bad Gateway",
                    headers: ["Content-Type": "text/plain; charset=utf-8"],
                    body: Data("502 Bad Gateway\n".utf8),
                    omitBody: false
                )
                return
            }
            try sendDiffViewerHTTPHeader(
                fileDescriptor: fd,
                status: 200,
                reason: "OK",
                headers: headers
            )
            return
        }

        try sendDiffViewerHTTPHeader(
            fileDescriptor: fd,
            status: 200,
            reason: "OK",
            headers: headers
        )
        try sendAllDiffViewerHTTPData(firstChunk, fileDescriptor: fd)

        while true {
            let data = try handle.read(upToCount: 64 * 1024) ?? Data()
            if data.isEmpty {
                break
            }
            try sendAllDiffViewerHTTPData(data, fileDescriptor: fd)
        }
        process.waitUntilExit()
    }

    private func sendDiffViewerHTTPNotFound(fileDescriptor fd: Int32, omitBody: Bool) throws {
        try sendDiffViewerHTTPResponse(
            fileDescriptor: fd,
            status: 404,
            reason: "Not Found",
            headers: ["Content-Type": "text/plain; charset=utf-8"],
            body: Data("404 Not Found\n".utf8),
            omitBody: omitBody
        )
    }

    private func sendDiffViewerHTTPResponse(
        fileDescriptor fd: Int32,
        status: Int,
        reason: String,
        headers: [String: String],
        body: Data,
        omitBody: Bool
    ) throws {
        var responseHeaders = diffViewerHTTPBaseHeaders(port: nil)
        for (key, value) in headers {
            responseHeaders[key] = value
        }
        responseHeaders["Content-Length"] = "\(body.count)"
        try sendDiffViewerHTTPHeader(
            fileDescriptor: fd,
            status: status,
            reason: reason,
            headers: responseHeaders
        )
        if !omitBody {
            try sendAllDiffViewerHTTPData(body, fileDescriptor: fd)
        }
    }

    private func sendDiffViewerHTTPHeader(
        fileDescriptor fd: Int32,
        status: Int,
        reason: String,
        headers: [String: String]
    ) throws {
        var header = "HTTP/1.1 \(status) \(reason)\r\n"
        for key in headers.keys.sorted() {
            guard let value = headers[key] else { continue }
            header += "\(key): \(value)\r\n"
        }
        header += "\r\n"
        try sendAllDiffViewerHTTPData(Data(header.utf8), fileDescriptor: fd)
    }

    private func sendAllDiffViewerHTTPData(_ data: Data, fileDescriptor fd: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let sent = Darwin.send(
                    fd,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset,
                    0
                )
                if sent < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw CLIError(message: "Failed to write diff viewer response: \(posixErrorMessage(errno))")
                }
                if sent == 0 {
                    throw CLIError(message: "Failed to write diff viewer response")
                }
                offset += sent
            }
        }
    }

    private func diffViewerHTTPBaseHeaders(port: Int?) -> [String: String] {
        var headers: [String: String] = [
            "Cache-Control": "no-store",
            "Connection": "close",
            "Cross-Origin-Resource-Policy": "same-origin",
            "X-Content-Type-Options": "nosniff"
        ]
        if let port {
            headers["Origin-Agent-Cluster"] = "?1"
            headers["Referrer-Policy"] = "no-referrer"
            headers["X-CMUX-Diff-Viewer-Origin"] = "http://127.0.0.1:\(port)"
        }
        return headers
    }

    private func diffViewerHTTPContentType(_ mimeType: String) -> String {
        if mimeType.hasPrefix("text/") {
            return "\(mimeType); charset=utf-8"
        }
        return mimeType
    }

    func diffViewerHTTPServerStateURL(rootDirectory: URL) -> URL {
        rootDirectory.appendingPathComponent(".server.json", isDirectory: false)
    }

    func diffViewerHTTPManifestURL(token: String, rootDirectory: URL) -> URL {
        rootDirectory.appendingPathComponent(".manifest-\(token).json", isDirectory: false)
    }

    func diffViewerHTTPIsValidToken(_ token: String) -> Bool {
        guard (16...80).contains(token.count) else { return false }
        return token.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-"
        }
    }

    private func diffViewerHTTPIsValidRequestPath(_ path: String) -> Bool {
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

    private func diffViewerHTTPIsAllowedMimeType(_ mimeType: String) -> Bool {
        mimeType == "text/html" || mimeType == "text/javascript" || mimeType == "text/x-diff"
    }

    private func diffViewerHTTPPathExtensionMatchesMimeType(path: String, mimeType: String) -> Bool {
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

    func posixErrorMessage(_ code: Int32) -> String {
        String(cString: strerror(code))
    }

}
