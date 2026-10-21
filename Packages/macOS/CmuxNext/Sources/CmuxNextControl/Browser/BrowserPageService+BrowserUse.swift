import CmuxNextSettings
import Foundation

/// `browser.page.drag` (`selector` onto `target`) and `browser.page.upload`
/// (`selector`, `files`: absolute paths) for `cmux browser <tab> drag|upload`
/// (browser use thread, user 2026-10-19). Both announce to the agent cursor:
/// a drag glides from the grab to the drop, an upload clicks the input.
extension BrowserPageService {
    /// The most bytes one upload sends into the page (the files ride in a page script).
    static let uploadLimit = 25 * 1024 * 1024

    func browserUseMethods() -> [ControlMethod] {
        let engine = engine
        return [
            .async("browser.page.drag") { call in
                let script = BrowserPageScripts.drag(try Self.string(call, "selector"), to: try Self.string(call, "target"))
                return try await Self.runInput(engine, call, script) { .from(kind: .drag, answer: $0) }
            },
            .async("browser.page.upload") { call in
                let selector = try Self.string(call, "selector")
                let files = try Self.uploadFiles(call)
                return try await Self.runInput(engine, call, BrowserPageScripts.upload(selector, files: files)) {
                    .from(kind: .click, answer: $0)
                }
            },
        ]
    }

    /// Reads `params.files` (absolute paths of regular files, at most
    /// ``uploadLimit`` bytes in all) as name, MIME type and base64.
    static func uploadFiles(_ call: ControlCall) throws -> [(name: String, type: String, base64: String)] {
        let paths = (call.request.params["files"]?.arrayValue ?? []).compactMap(\.stringValue)
        guard !paths.isEmpty else {
            throw ControlError.invalidParams(ControlStrings.format("control.error.missingParam", "%1$@ requires params.%2$@",
                                                                   call.request.method, "files"))
        }
        var total = 0
        return try paths.map { path in
            let url = URL(fileURLWithPath: path)
            var isDirectory: ObjCBool = false
            guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  let data = FileManager.default.contents(atPath: path) else {
                throw ControlError(code: "not_found", message: ControlStrings.format("control.error.uploadFileMissing", "No file to upload at %@", path))
            }
            total += data.count
            guard total <= uploadLimit else {
                throw ControlError(code: "too_large", message: ControlStrings.text("control.error.uploadTooLarge", "The files to upload are larger than 25 MB"))
            }
            return (url.lastPathComponent, mimeType(url.pathExtension), data.base64EncodedString())
        }
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
