import CmuxNextCompat
import CmuxNextSettings
import Foundation

/// `browser.page.drag` (`selector` onto `target`) and `browser.page.upload`
/// (`selector`, `files`: absolute paths) for `cmux browser <tab> drag|upload`
/// (browser use thread, user 2026-10-19). Both announce to the agent cursor:
/// a drag glides from the grab to the drop, an upload clicks the input.
/// An upload goes through the page's own file chooser (``BrowserPageUpload``),
/// so a button or a hidden input works and the files keep their size; a file
/// input whose page opens no chooser gets them through a page script.
/// `browser.page.downloads` and `browser.page.download.wait` read the app's
/// downloads list for `cmux browser <tab|page> download …`.
extension BrowserPageService {
    /// A page-script fallback sends one chunk per evaluation. The chooser path
    /// still hands the browser the original URLs without reading them here.
    static let uploadChunkBytes = 256 * 1024

    func browserUseMethods() -> [ControlMethod] {
        let engine = engine
        return [
            .async("browser.page.drag") { call in
                let script = BrowserPageScripts.drag(try Self.string(call, "selector"), to: try Self.string(call, "target"))
                return try await Self.runInput(engine, call, script) { .from(kind: .drag, answer: $0) }
            },
            .async("browser.page.upload") { call in
                let selector = try Self.string(call, "selector")
                let files = try Self.uploadURLs(call)
                let tab = try Self.tab(call)
                let within = Duration.milliseconds(Self.uploadChooserWait(call))
                let upload = BrowserPageUpload(script: BrowserPageScripts.openFileChooser(selector), files: files, within: within)
                let answer = try await Self.run(engine, .upload(upload), tab)
                let value = answer["value"] ?? .null
                if let error = value["error"]?.stringValue {
                    throw ControlError(code: value["code"]?.stringValue ?? "not_found", message: error, data: ["selector": .string(selector)])
                }
                switch answer["chooser"]?.stringValue {
                case "chosen"?:
                    await engine.announce(Self.attributed(.from(kind: .click, answer: value), call), tabID: tab.id)
                    var result = Self.base(tab)
                    result["value"] = ["files": .array(files.map { .string($0.lastPathComponent) }), "chooser": true]
                    return .object(result)
                case "withdrawn"? where value["value"]?["fileInput"]?.boolValue != true:
                    throw ControlError(code: "no_file_chooser",
                                       message: ControlStrings.format("control.error.uploadNoChooser", "Clicking %@ opened no file chooser", selector),
                                       data: ["selector": .string(selector)])
                case "withdrawn"?, "unsupported"?, nil:
                    // A file input whose page opened no chooser (or an engine without one): stream
                    // the files through successive page evaluations instead of putting the whole
                    // payload in one script or refusing it at an arbitrary size.
                    return try await Self.streamUpload(engine, call, selector: selector)
                case let refusal?:
                    throw ControlError(code: refusal, message: Self.refusalMessage(refusal), data: ["selector": .string(selector)])
                }
            }.withDeadline(.fixed(Self.uploadDeadline)),
            .async("browser.page.downloads") { call in
                let limit = call.request.params["limit"]?.intValue
                let answer = try await engine.downloads(BrowserPageDownloadQuery(tabID: try Self.downloadTab(call), limit: limit))
                guard case .list(let rows) = answer else { return ["downloads": []] }
                return ["downloads": .array(rows.map(\.json))]
            },
            .async("browser.page.download.wait") { call in
                let ms = min(max(call.request.params["timeout_ms"]?.intValue ?? Self.downloadWaitDefaultMs, 1), Self.downloadWaitMaxMs)
                let id = Self.optionalString(call, "id")
                let answer = try await engine.downloads(BrowserPageDownloadQuery(tabID: try Self.downloadTab(call), id: id, wait: .milliseconds(ms)))
                let row: BrowserPageDownload
                switch answer {
                case .ended(let ended): row = ended
                case .unknownID:
                    throw ControlError(code: "not_found", message: ControlStrings.format("control.error.downloadNotFound", "No download %@", id ?? ""))
                case .timedOut, .list:
                    throw ControlError(code: "timeout", message: ControlStrings.format("control.error.downloadTimedOut",
                                                                                       "No download ended within %@ ms", String(ms)))
                }
                guard row.status == "finished" else {
                    throw ControlError(code: "download_failed", message: ControlStrings.format("control.error.downloadFailed",
                                                                                               "The download %1$@ did not finish (%2$@)",
                                                                                               row.filename, row.reason ?? row.status),
                                       data: row.json)
                }
                var result: [String: JSONValue] = ["download": row.json]
                if let target = Self.optionalString(call, "path") {
                    guard let source = row.path else {
                        throw ControlError(code: "io_error", message: ControlStrings.format("control.error.downloadCopyFailed",
                                                                                            "Could not save the download to %1$@: %2$@",
                                                                                            target, row.filename))
                    }
                    result["path"] = .string(try Self.copyDownload(from: source, to: target))
                }
                return .object(result)
            }.withDeadline(.fixed(.milliseconds(Self.downloadWaitMaxMs) + .seconds(5))),
        ]
    }

    /// An upload's limit past the control plane's: the page's first load (15 s at most), the longest chooser
    /// wait (60 s) and the page-script fallback. The call's own waits end it sooner.
    static let uploadDeadline: Duration = .seconds(90)

    /// How long `browser.page.upload` waits for a chooser after its click: `params.timeout_ms`, 3 s by default.
    static func uploadChooserWait(_ call: ControlCall) -> Int {
        min(max(call.request.params["timeout_ms"]?.intValue ?? 3_000, 100), 60_000)
    }

    /// A `browser.page.download.wait` lasts `params.timeout_ms`: 30 s by default, at most 10 min.
    static let downloadWaitDefaultMs = 30_000
    static let downloadWaitMaxMs = 600_000

    /// The tab whose downloads a download method reads: `params.tab` when given (resolved as every page
    /// method does); without one, every tab's.
    static func downloadTab(_ call: ControlCall) throws -> String? {
        guard optionalString(call, "tab") != nil else { return nil }
        return try tab(call).id
    }

    /// Copies a finished download to `target` (a folder takes the file's name) and answers the copy's path.
    /// Nothing is removed or replaced: a target that is the download answers its path, and any other existing
    /// file or folder there is refused.
    static func copyDownload(from source: String, to target: String) throws -> String {
        let manager = FileManager.checked
        let from = URL(fileURLWithPath: source)
        var to = URL(fileURLWithPath: target)
        var isFolder: ObjCBool = false
        if target.hasSuffix("/") || (manager.fileExists(atPath: to.path, isDirectory: &isFolder) && isFolder.boolValue) {
            to = to.appendingPathComponent(from.lastPathComponent)
        }
        let failed = { (reason: String) in
            ControlError(code: "io_error", message: ControlStrings.format("control.error.downloadCopyFailed",
                                                                          "Could not save the download to %1$@: %2$@", to.path, reason))
        }
        if manager.fileExists(atPath: to.path) {
            // The same file by identity, not by spelling (a case-insensitive volume, a hard link).
            if let source = try? from.blockingResourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
               let existing = try? to.blockingResourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
               source.isEqual(existing) {
                return from.path
            }
            throw failed(ControlStrings.text("control.error.downloadTargetExists", "a file is already there"))
        }
        do {
            try manager.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.copyItem(at: from, to: to)
        } catch {
            throw failed(error.localizedDescription)
        }
        return to.path
    }

    /// The message for a chooser that could not take the files (``BrowserAgentFiles``'s refusal codes).
    static func refusalMessage(_ code: String) -> String {
        switch code {
        case "too_many_files": ControlStrings.text("control.error.uploadTooManyFiles", "The file input takes one file")
        case "needs_folder": ControlStrings.text("control.error.uploadNeedsFolder", "The file input takes one folder")
        case "needs_files": ControlStrings.text("control.error.uploadNeedsFiles", "The file input takes files, not folders")
        default: ControlStrings.text("control.error.uploadSaveChooser", "The page asked where to save a file, not for files to upload")
        }
    }

    /// `params.files` as file URLs: absolute paths of files or folders that exist (a folder's URL has
    /// `hasDirectoryPath`). Nothing is read: the page's chooser takes the files themselves.
    static func uploadURLs(_ call: ControlCall) throws -> [URL] {
        let paths = (call.request.params["files"]?.arrayValue ?? []).compactMap(\.stringValue)
        guard !paths.isEmpty else {
            throw ControlError.invalidParams(ControlStrings.format("control.error.missingParam", "%1$@ requires params.%2$@",
                                                                   call.request.method, "files"))
        }
        return try paths.map { path in
            var isDirectory: ObjCBool = false
            guard path.hasPrefix("/"), FileManager.checked.fileExists(atPath: path, isDirectory: &isDirectory) else {
                throw ControlError(code: "not_found", message: ControlStrings.format("control.error.uploadFileMissing", "No file to upload at %@", path))
            }
            return URL(fileURLWithPath: path, isDirectory: isDirectory.boolValue)
        }
    }

    /// Reads and validates `params.files` as regular files without imposing a
    /// total-size limit. The page fallback reads each file incrementally via
    /// ``streamUpload``.
    static func uploadFiles(_ call: ControlCall) throws -> [(url: URL, name: String, type: String)] {
        let paths = (call.request.params["files"]?.arrayValue ?? []).compactMap(\.stringValue)
        guard !paths.isEmpty else {
            throw ControlError.invalidParams(ControlStrings.format("control.error.missingParam", "%1$@ requires params.%2$@",
                                                                   call.request.method, "files"))
        }
        return try paths.map { path in
            let url = URL(fileURLWithPath: path)
            var isDirectory: ObjCBool = false
            guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                throw ControlError(code: "not_found", message: ControlStrings.format("control.error.uploadFileMissing", "No file to upload at %@", path))
            }
            // A FIFO can block the open beyond cancellation's reach and a device like /dev/zero never
            // ends, so only a regular file (after its links resolve) is streamed.
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
            guard attributes?[.type] as? FileAttributeType == .typeRegular else {
                throw ControlError(code: "not_regular_file",
                                   message: ControlStrings.format("control.error.uploadNotRegularFile", "Only regular files can be uploaded: %@", path))
            }
            return (url, url.lastPathComponent, mimeType(url.pathExtension))
        }
    }

    /// Streams regular files into the page's file input in bounded evaluations.
    /// The browser assembles the chunks into `File` objects only at the end.
    static func streamUpload(_ engine: any BrowserPageEngine, _ call: ControlCall, selector: String) async throws -> JSONValue {
        let files = try Self.uploadFiles(call)
        let metadata = files.map { (name: $0.name, type: $0.type) }
        let uploadID = UUID().uuidString
        do {
            try Task.checkCancellation()
            _ = try await Self.runInput(engine, call, BrowserPageScripts.startUpload(selector, id: uploadID, files: metadata)) { _ in nil }
            for (index, file) in files.enumerated() {
                let handle = try FileHandle(forReadingFrom: file.url)
                defer { try? handle.close() }
                while let chunk = try Self.readUploadChunk(handle) {
                    let encoded = chunk.base64EncodedString()
                    _ = try await Self.runInput(engine, call, BrowserPageScripts.uploadChunk(selector, id: uploadID, index: index, base64: encoded)) { _ in nil }
                }
            }
            try Task.checkCancellation()
            return try await Self.runInput(engine, call, BrowserPageScripts.finishUpload(selector, id: uploadID)) {
                .from(kind: .click, answer: $0)
            }
        } catch {
            _ = try? await Self.runInput(engine, call, BrowserPageScripts.cancelUpload(selector, id: uploadID)) { _ in nil }
            throw error
        }
    }

    /// Cancellation is checked before every file read, including the EOF read.
    private static func readUploadChunk(_ handle: FileHandle) throws -> Data? {
        try Task.checkCancellation()
        guard let chunk = try handle.read(upToCount: uploadChunkBytes), !chunk.isEmpty else { return nil }
        return chunk
    }

    /// A MIME type for a file extension; `application/octet-stream` when unknown.
    static func mimeType(_ ext: String) -> String {
        switch ext.lowercased() {
        case "txt", "md", "log": "text/plain"
        case "csv": "text/csv"
        case "html", "htm": "text/html"
        case "json": "application/json"
        case "pdf": "application/pdf"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "svg": "image/svg+xml"
        case "zip": "application/zip"
        case "mp4": "video/mp4"
        default: "application/octet-stream"
        }
    }

    /// Runs an input page script on the tab, maps `{error, code}` to an error,
    /// and announces what `announce` makes of the answer, by `params.agent`.
    static func runInput(_ engine: any BrowserPageEngine, _ call: ControlCall, _ script: String,
                         announce: (JSONValue) -> BrowserPageAgentInput?) async throws -> JSONValue {
        let tab = try Self.tab(call)
        let value = try await Self.run(engine, .evaluate(script), tab)["value"] ?? .null
        if let error = value["error"]?.stringValue {
            var data: [String: JSONValue] = [:]
            if let selector = call.request.params["selector"] { data["selector"] = selector }
            throw ControlError(code: value["code"]?.stringValue ?? "not_found", message: error, data: .object(data))
        }
        if let input = announce(value) {
            await engine.announce(Self.attributed(input, call), tabID: tab.id)
        }
        var result = Self.base(tab)
        result["value"] = value["value"] ?? .null
        return .object(result)
    }
}
