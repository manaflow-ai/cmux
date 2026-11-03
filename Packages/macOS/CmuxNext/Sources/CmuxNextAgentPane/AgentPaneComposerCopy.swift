public import Foundation
import AppKit
import CmuxNextCompat
import UniformTypeIdentifiers

/// One attachment the composer's Copy or Cut carries (`composer.copy`; the user, 2026-11-01: "i
/// wanna be able to select all in composer which also selects all the attachments as the copy as
/// well"). The page sends what it holds: an image preview, a PDF or audio as base64 bytes, a text
/// file or a pasted-text chip as its text, or a file the person attached from this Mac as its path.
/// Every value is untrusted page input: the keys are fixed, the transport is chunked, and the host checks a
/// path again before it puts the file on the pasteboard.
public nonisolated struct AgentPaneComposerCopyItem: Equatable, Sendable {
    public enum Payload: Equatable, Sendable {
        /// The bytes, base64 without a `data:` prefix.
        case data(String)
        /// A text file's contents, UTF-8.
        case text(String)
        /// An absolute path on this Mac (a file or a folder the person attached).
        case path(String)
        /// An opaque, one-copy reference to locally staged bytes in this pane/session.
        case reference(String)
    }

    public var name: String
    public var mimeType: String
    public var payload: Payload

    public init(name: String, mimeType: String, payload: Payload) {
        self.name = name
        self.mimeType = mimeType
        self.payload = payload
    }

    /// Longest text (the selection's, or one text item's), in UTF-8 bytes.
    static let maximumText = 8 << 20
    /// Longest name or type, in UTF-8 bytes.
    static let maximumName = 255
    /// Longest base64 of one item (``AgentPaneImageCopies/maximumBytes`` decoded).
    static let maximumBase64 = AgentPaneImageCopies.maximumBytes / 3 * 4 + 64
    static let keys: Set<String> = ["name", "mimeType", "data", "text", "path", "reference"]

    /// The item one JSON object names, nil when it breaks the contract: an unknown key, a missing
    /// name or type, not exactly one of `data`, `text` and `path`, or a value over its cap.
    init?(json: Any) {
        guard let object = json as? [String: Any], Set(object.keys).isSubset(of: Self.keys),
              let name = object["name"] as? String, name.utf8.count <= Self.maximumName, !name.utf8.contains(0),
              let mimeType = object["mimeType"] as? String, mimeType.utf8.count <= Self.maximumName,
              !mimeType.utf8.contains(0) else { return nil }
        let present = ["data", "text", "path", "reference"].filter { object[$0] != nil }
        guard present.count == 1 else { return nil }
        let payload: Payload
        switch present[0] {
        case "data":
            guard let base64 = object["data"] as? String, !base64.isEmpty, base64.utf8.count <= Self.maximumBase64 else { return nil }
            payload = .data(base64)
        case "text":
            guard let text = object["text"] as? String, text.utf8.count <= Self.maximumText, !text.utf8.contains(0) else { return nil }
            payload = .text(text)
        case "reference":
            guard let reference = object["reference"] as? String, UUID(uuidString: reference) != nil else { return nil }
            payload = .reference(reference)
        default:
            guard let path = object["path"] as? String, path.hasPrefix("/"), path.utf8.count <= AgentPaneReplyPaths.maximumLength,
                  !path.utf8.contains(0) else { return nil }
            payload = .path(path)
        }
        self.init(name: name, mimeType: mimeType, payload: payload)
    }

    /// One or more valid items, without a count or aggregate byte cap.
    static func list(_ raw: Any?) -> [Self]? {
        guard let values = raw as? [Any], !values.isEmpty else { return nil }
        var items: [Self] = []
        for value in values {
            guard let item = Self(json: value) else { return nil }
            items.append(item)
        }
        return items
    }
}

extension AgentPaneImageCopies {
    /// An attachment made ready off the main actor: the file the pasteboard names, and for an
    /// image its bytes under its type and as TIFF.
    struct ComposerFile: Sendable {
        var file: URL
        var imageType: String?
        var image: Data?
        var tiff: Data?
        /// A file of this Mac the person attached (not a copy the host wrote).
        var isLocal: Bool
        /// The request's item this file is, by its index.
        var index = 0
    }

    /// `composer.copy`: spends the person's Copy key, writes each data or text item as a file under
    /// its own plain name in the copies folder (``writeComposerFile(_:item:fallback:in:)``; an SVG
    /// rebuilt first), checks each path again, and replaces the general pasteboard's contents with the
    /// text (when there is any), then one file item per attachment kept, in order. An item that is
    /// refused or cannot be read is left out; with no text and nothing kept, nothing is written.
    @MainActor static func copyComposer(text: String, items: [AgentPaneComposerCopyItem], in model: AgentPaneModel,
                                       references: [String: URL]? = nil, order: String? = nil,
                                       published: @MainActor () -> Void = {}) async -> [String: Any] {
        if references == nil, !model.transport.gestures.consume() { return AgentPaneModel.replyFailure(.gestureRequired) }
        if references == nil { model.replyLinks.composerCopyRevision = UUID() }
        let revision = model.replyLinks.composerCopyRevision
        let generation = model.droppedPaths.generation
        let folder = model.replyLinks.imageFolder.appendingPathComponent("Composer Copies", isDirectory: true)
        var files = await composerFiles(items, localPaths: !model.chatIsElsewhere, home: model.replyLinks.home, in: folder,
                                        references: references ?? [:])
        let copyID = UUID().uuidString
        var names = [String?](repeating: nil, count: items.count)
        for file in files { names[file.index] = file.file.lastPathComponent }
        let html = await composerHTML(text, copyID: copyID, order: order, files: names)
        // The files were made off the main actor: a chat that turned remote meanwhile puts none of
        // this Mac's own files on the pasteboard (cx-k21v).
        if model.chatIsElsewhere { files.removeAll { $0.isLocal } }
        guard !Task.isCancelled, model.droppedPaths.generation == generation, model.replyLinks.composerCopyRevision == revision,
              references == nil || files.count == items.count else { return AgentPaneModel.replyFailure(.openFailed) }
        guard !files.isEmpty || !text.isEmpty else { return AgentPaneModel.replyFailure(.openFailed) }
        var board: [NSPasteboardItem] = []
        if !text.isEmpty {
            let item = NSPasteboardItem()
            item.setString(text, forType: .string)
            board.append(item)
        }
        board += files.map { composerPasteboardItem($0) }
        board[0].setString(html, forType: .html)
        guard model.replyLinks.copyItems(board) else { return AgentPaneModel.replyFailure(.openFailed) }
        published()
        // Each kept file's item and name: the page knows its own copy again by them on a paste, which
        // WebKit gives the files of with no text while the pasteboard holds file URLs.
        let written: [[String: Any]] = files.map { ["item": $0.index, "name": $0.file.lastPathComponent] }
        return AgentPaneReply.success(["copied": files.count, "skipped": items.count - files.count, "files": written, "copyID": copyID])
    }

    /// WebKit keeps HTML beside file URLs even when it withholds their plain text. A new screenshot
    /// has no copy marker, so a matching file name cannot bring back an older prompt.
    @concurrent static func composerHTML(_ text: String, copyID: String, order: String? = nil, files: [String?] = []) async -> String {
        let escaped = text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let html = "<span data-cmux-composer-copy=\"\(copyID)\" style=\"white-space: pre-wrap\">\(escaped)</span>"
        guard let order, let encoded = try? JSONEncoder().encode(files), let names = String(data: encoded, encoding: .utf8) else { return html }
        let metadata = [order, names].map {
            $0.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        return html + "<span hidden data-cmux-composer-order=\"\(metadata[0])\" data-cmux-composer-files=\"\(metadata[1])\"></span>"
    }

    /// The pasteboard item of one attachment: as ``pasteboardItem(_:data:)``, with the TIFF made
    /// off the main actor.
    @MainActor static func composerPasteboardItem(_ copy: ComposerFile) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(copy.file.absoluteString, forType: .fileURL)
        item.setString(copy.file.lastPathComponent, forType: .string)
        if let type = copy.imageType, let image = copy.image {
            item.setData(image, forType: NSPasteboard.PasteboardType(type))
            if let tiff = copy.tiff { item.setData(tiff, forType: .tiff) }
        }
        return item
    }

    /// Each item's file, in order. Image representation guards only control pixel decoding;
    /// a larger original remains a file URL, with no count or aggregate byte limit.
    @concurrent static func composerFiles(_ items: [AgentPaneComposerCopyItem], localPaths: Bool, home: String,
                                          in folder: URL, references: [String: URL] = [:]) async -> [ComposerFile] {
        var files: [ComposerFile] = []
        for (index, item) in items.enumerated() {
            let file: URL?
            var isLocal = false
            switch item.payload {
            case .data(let base64):
                file = Data(base64Encoded: base64, options: .ignoreUnknownCharacters)
                    .flatMap { $0.isEmpty || $0.count > maximumBytes ? nil : $0 }
                    .flatMap { writeComposerFile($0, item: item, fallback: "bin", in: folder) }
            case .text(let text):
                file = writeComposerFile(Data(text.utf8), item: item, fallback: "txt", in: folder)
            case .path(let path):
                guard localPaths else { continue }
                file = await attachedFile(path, home: home, in: folder)
                isLocal = true
            case .reference(let reference):
                file = references[reference].flatMap { referenceFile($0, item: item, in: folder) }
            }
            guard let file else { continue }
            let imageType = file.hasDirectoryPath ? nil : UTType(filenameExtension: file.pathExtension).flatMap { $0.conforms(to: .image) ? $0 : nil }
            let image = imageType == nil ? nil : regularFileBytes(file, limit: maximumBytes)
            let tiff = imageType == UTType.tiff ? nil : image.flatMap { NSImage(data: $0)?.tiffRepresentation }
            files.append(ComposerFile(file: file, imageType: image == nil ? nil : imageType?.identifier, image: image, tiff: tiff,
                                      isLocal: isLocal, index: index))
        }
        return files
    }

    /// Publishes owned staged bytes under the attachment's plain name, without reading them into
    /// memory. An SVG still crosses the existing sanitizer before it can leave the app.
    nonisolated static func referenceFile(_ staged: URL, item: AgentPaneComposerCopyItem, in folder: URL) -> URL? {
        let ext = composerExtension(item.name, mimeType: item.mimeType, fallback: "bin")
        let destination = staged.deletingLastPathComponent()
            .appendingPathComponent("\(baseName(item.name, fallback: "Attachment")).\(ext)")
        if ext.lowercased() == "svg" || item.mimeType.lowercased() == "image/svg+xml" {
            guard let bytes = regularFileBytes(staged, limit: AgentPaneReplyImages.maximumBytes) else { return nil }
            return writeComposerFile(bytes, item: item, fallback: ext, in: folder)
        }
        do {
            if staged != destination { try FileManager.checked.moveItem(at: staged, to: destination) }
            return destination
        } catch { return nil }
    }

    /// Reads selection text once for the platform's string pasteboard representation. Transport
    /// and attachment files remain chunked; AppKit requires this final string in memory.
    @concurrent static func stagedText(_ file: URL) async -> String? {
        guard let text = try? String(blockingContentsOf: file, encoding: .utf8), !text.utf8.contains(0) else { return nil }
        return text
    }

    /// Writes `data` as `item`'s file in `folder` (once per content), under its plain name so a
    /// paste anywhere shows "report.pdf": `<short hash of the bytes>/<name>.<ext>`, the name made
    /// one plain file name (``baseName(_:fallback:)``) and the extension its name's, else its
    /// type's, else `fallback`. The hash folder keeps two attachments of one name apart. An SVG
    /// (by extension or type) is written only as its rebuilt form (media-safety R7). Nil when it
    /// cannot be written.
    nonisolated static func writeComposerFile(_ data: Data, item: AgentPaneComposerCopyItem, fallback: String, in folder: URL) -> URL? {
        let ext = composerExtension(item.name, mimeType: item.mimeType, fallback: fallback)
        var data = data
        if ext.lowercased() == "svg" || item.mimeType.lowercased() == "image/svg+xml" {
            guard let clean = AgentPaneSVGSanitizer.sanitize(data) else { return nil }
            data = clean
        }
        let place = folder.appendingPathComponent(shortHash(data), isDirectory: true)
        let file = place.appendingPathComponent("\(baseName(item.name, fallback: "Attachment")).\(ext)", isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
            if regularFileBytes(file, limit: data.count) != data { try data.write(to: file, options: .atomic) }
            return file
        } catch {
            return nil
        }
    }

    /// The extension a copy keeps: its name's as spelled (1 to 5 letters or digits, as ``baseName(_:fallback:)``
    /// strips it), else an image type's own (``extensions``), else the one its type prefers, else
    /// `fallback`.
    nonisolated static func composerExtension(_ name: String, mimeType: String, fallback: String) -> String {
        if let range = name.range(of: "\\.[A-Za-z0-9]{1,5}$", options: .regularExpression) {
            return String(name[range].dropFirst())
        }
        if let ext = extensions[mimeType.lowercased()] { return ext }
        if let ext = UTType(mimeType: mimeType.lowercased())?.preferredFilenameExtension,
           ext.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.alphanumerics.contains($0) }) {
            return ext
        }
        return fallback
    }

    /// The file an attached `path` names when it may go on the pasteboard: it exists, its canonical
    /// path is not on the deny list (composer attachments may lie outside the pane's roots, so no
    /// root is required), and an SVG goes out as its rebuilt copy (``handedOut(_:in:)``).
    @concurrent static func attachedFile(_ path: String, home: String, in folder: URL) async -> URL? {
        let paths = AgentPaneReplyPaths(roots: [], home: home, base: nil)
        guard !paths.isDenied(path), let canonical = AcpmuxPathPolicy.canonical(path), !paths.isDenied(canonical) else { return nil }
        let file = URL(fileURLWithPath: canonical, isDirectory: AcpmuxPathPolicy.isDirectory(canonical))
        let out = handedOut(file, in: folder)
        if out != file, await !rebuild(file, to: out) { return nil }
        return out
    }
}
