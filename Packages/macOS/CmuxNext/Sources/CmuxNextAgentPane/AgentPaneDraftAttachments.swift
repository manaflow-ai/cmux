public import CmuxNextSettings
import CryptoKit
public import Foundation

/// The ordered content of an agent composer draft.
///
/// Text uses one object-replacement character per attachment, just as AppKit's text attachment
/// model does. Keeping the marks in the text means a paste or drop has one insertion point and the
/// attachment array remains a compact, durable description of the same draft. The marks never go
/// on the ACP wire; ``acpContentBlocks`` expands them in order.
public nonisolated struct AgentPaneDraft: Codable, Sendable, Equatable {
    /// The character that occupies one attachment's place in ``text``.
    public static let attachmentMark: Unicode.Scalar = "\u{FFFC}"

    /// The editable text, including one ``attachmentMark`` for each inline attachment.
    public var text: String
    /// Attachments in the order of the marks in ``text``.
    public var attachments: [AgentPaneWakeState.Attachment]

    /// A piece in the order a composer displays and sends it.
    public enum Piece: Equatable, Sendable {
        /// A text run between two attachments.
        case text(String)
        /// One inline attachment.
        case attachment(AgentPaneWakeState.Attachment)
    }

    /// Creates an ordered draft. `text` may contain no marks when the draft is text-only.
    public init(text: String = "", attachments: [AgentPaneWakeState.Attachment] = []) {
        self.text = text
        self.attachments = attachments
    }

    /// The editable text without its object-replacement marks.
    public var plainText: String { Self.stripMarks(text) }

    /// The text and attachments in their inline order.
    public var pieces: [Piece] {
        var result: [Piece] = []
        var run = String.UnicodeScalarView()
        var next = 0
        func flush() {
            guard !run.isEmpty else { return }
            result.append(.text(String(run)))
            run = String.UnicodeScalarView()
        }
        for scalar in text.unicodeScalars {
            guard scalar == Self.attachmentMark else {
                run.append(scalar)
                continue
            }
            flush()
            if attachments.indices.contains(next) {
                let attachment = attachments[next]
                result.append(.attachment(attachment))
            }
            next += 1
        }
        flush()
        // A malformed or older draft can have attachments with no mark. Keeping them at the end
        // is lossless and matches the old tray's order while the next edit repairs the marks.
        result.append(contentsOf: attachments.dropFirst(next).map(Piece.attachment))
        return result
    }

    /// ACP content blocks in exactly the order represented by ``pieces``.
    ///
    /// Attachments whose bytes were not retained are omitted, as they were by the tray path; a
    /// link attachment still has a resource block because it is sent by reference. An image that
    /// also has an original path produces its image block followed by that reference block.
    public var acpContentBlocks: [JSONValue] {
        pieces.flatMap { Self.blocks(for: $0) }
    }

    /// Alias used by callers that describe the ACP value as prompt blocks.
    public var promptContentBlocks: [JSONValue] { acpContentBlocks }

    /// Inserts an attachment at a UTF-16 caret offset. A nil or out-of-range offset means the end.
    public mutating func insert(_ attachment: AgentPaneWakeState.Attachment, atUTF16Offset offset: Int?) {
        let source = text as NSString
        let location = min(max(0, offset ?? source.length), source.length)
        let marks = Self.markOffsets(text)
        let mark = String(Character(Self.attachmentMark))
        if marks.count == attachments.count {
            let index = marks.reduce(into: 0) { count, markOffset in
                if markOffset < location { count += 1 }
            }
            attachments.insert(attachment, at: min(index, attachments.count))
        } else {
            // Keep malformed drafts editable: appending is safer than assigning an attachment to
            // an unrelated mark that came from pasted plain text or an old undo stack.
            attachments.append(attachment)
        }
        text = source.replacingCharacters(in: NSRange(location: location, length: 0), with: mark)
    }

    /// Removes an attachment and its mark when the draft is internally consistent.
    public mutating func removeAttachment(id: String) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        let marks = Self.markOffsets(text)
        attachments.remove(at: index)
        guard marks.count == attachments.count + 1, marks.indices.contains(index) else { return }
        let location = marks[index]
        text = (text as NSString).replacingCharacters(in: NSRange(location: location, length: 1), with: "")
    }

    /// The UTF-16 offsets of attachment marks, in order.
    public static func markOffsets(_ text: String) -> [Int] {
        var offsets: [Int] = []
        var offset = 0
        for unit in text.utf16 {
            if unit == attachmentMark.value { offsets.append(offset) }
            offset += 1
        }
        return offsets
    }

    /// Removes all object-replacement marks from editable text.
    public static func stripMarks(_ text: String) -> String {
        guard text.unicodeScalars.contains(attachmentMark) else { return text }
        var result = String.UnicodeScalarView()
        result.append(contentsOf: text.unicodeScalars.filter { $0 != attachmentMark })
        return String(result)
    }

    private static func blocks(for piece: Piece) -> [JSONValue] {
        switch piece {
        case .text(let text):
            return text.isEmpty ? [] : [.object(["type": .string("text"), "text": .string(text)])]
        case .attachment(let attachment):
            return blocks(for: attachment)
        }
    }

    private static func blocks(for attachment: AgentPaneWakeState.Attachment) -> [JSONValue] {
        var blocks: [JSONValue] = []
        switch attachment.kind {
        case "image":
            guard let data = attachment.data else { break }
            blocks.append(.object([
                "type": .string("image"),
                "mimeType": .string(attachment.mimeType),
                "data": .string(data),
                "name": .string(attachment.name),
            ]))
        case "document":
            guard let data = attachment.data else { break }
            blocks.append(.object([
                "type": .string("document"),
                "mimeType": .string(attachment.mimeType),
                "data": .string(data),
                "name": .string(attachment.name),
            ]))
        case "audio":
            guard let data = attachment.data else { break }
            blocks.append(.object([
                "type": .string("audio"),
                "mimeType": .string(attachment.mimeType),
                "data": .string(data),
            ]))
        case "link":
            guard let path = attachment.path else { break }
            blocks.append(.object([
                "type": .string("resource_link"),
                "uri": .string(fileURI(path)),
                "name": .string(attachment.name),
            ]))
        case "pasted":
            guard let text = attachment.text else { break }
            blocks.append(.object([
                "type": .string("text"),
                "text": .string(text),
                "_meta": .object(["cmux": .object(["pasted": .bool(true)])]),
            ]))
        case "text" where attachment.text != nil:
            blocks.append(.object([
                "type": .string("text"),
                "text": .string(textFileBody(attachment)),
            ]))
        default:
            break
        }
        if let originalPath = attachment.originalPath, attachment.kind == "image" {
            blocks.append(.object([
                "type": .string("resource_link"),
                "uri": .string(fileURI(originalPath)),
                "name": .string(attachment.originalName ?? attachment.name),
            ]))
        }
        return blocks
    }

    private static func textFileBody(_ attachment: AgentPaneWakeState.Attachment) -> String {
        let body = attachment.text ?? ""
        var backticks = 3
        var run = 0
        for scalar in body {
            if scalar == "`" {
                run += 1
                backticks = max(backticks, run + 1)
            } else {
                run = 0
            }
        }
        let extensionName = attachment.name.split(separator: ".").last.map(String.init) ?? ""
        let language = extensionName.range(of: "^[A-Za-z0-9+#-]{1,12}$", options: .regularExpression) != nil ? extensionName : ""
        let fence = String(repeating: "`", count: backticks)
        return "\(attachment.name)\n\(fence)\(language)\n\(body)\(body.hasSuffix("\n") ? "" : "\n")\(fence)"
    }

    private static func fileURI(_ path: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let encoded = path.split(separator: "/", omittingEmptySubsequences: false).map { part in
            String(part).addingPercentEncoding(withAllowedCharacters: allowed) ?? String(part)
        }.joined(separator: "/")
        return "file://\(encoded)"
    }
}

/// Each agent chat's unsent composer chips (pasted screenshots, PDFs, files and folders), by
/// session, in ``directoryName`` beside the launch snapshot: one folder per chat with its chips'
/// list and their contents as files of their own. Leo 2026-10-20: a draft's text came back and its
/// pictures did not, after a quit, after reopening the chat and after restoring it from the archive.
/// acpmux keeps the text with the session; this keeps the chips, so every path that shows the chat
/// again (reopen, archive and restore, delete and restore, a relaunch or a crash) gets them back.
/// The page writes its chat's chips once they settle (`chat.draftAttachments`) and reads them when
/// the chat shows (`chat.draftAttachments.get`); sending or removing the last chip forgets them.
@MainActor
public final class AgentPaneDraftAttachments {
    public static let directoryName = "agent-draft-attachments"
    nonisolated static let listName = "draft.json"
    /// The app's store; nil keeps no chips (a test host, the gallery).
    public static var shared: AgentPaneDraftAttachments?
    /// The most recently written chats are kept.
    nonisolated static let limit = 100
    /// One chat's files: a composer full of images (10 of at most 5 MB, `attachments.ts`) fits.
    public var maximumBytes = 64 * 1024 * 1024
    let directory: URL?
    /// Each chat's last queued read or write: the next one waits for it, so they run in the order
    /// the page asked, a later small write never overtaking an earlier large one.
    private var queue: [String: Task<Void, Never>] = [:]

    public init(directory: URL?) {
        self.directory = directory?.appending(path: Self.directoryName, directoryHint: .isDirectory)
    }

    /// The chips chat `sessionId` was left with, contents read back; empty when it holds none.
    public func attachments(for sessionId: String) async -> [AgentPaneWakeState.Attachment] {
        guard let folder = folder(for: sessionId) else { return [] }
        let limit = maximumBytes
        return await queued(sessionId) { Self.read(folder, limit: limit) }
    }

    /// The ordered draft left by chat `sessionId`; old stores read as a draft with empty text.
    public func draft(for sessionId: String) async -> AgentPaneDraft {
        guard let folder = folder(for: sessionId) else { return AgentPaneDraft() }
        let limit = maximumBytes
        return await queued(sessionId) { Self.readDraft(folder, limit: limit) }
    }

    /// Keeps `list` (the page's chips, as JSON) as chat `sessionId`'s chips; none forgets them. A
    /// chip sent without its contents keeps the file it already has. Answers the ids of the chips
    /// whose contents are kept, so the page knows which it need not send again; nil when `list` is
    /// not a list of chips. The list is decoded in the chat's queue, off the main actor.
    public func keep(_ list: JSONValue, for sessionId: String) async -> [String]? {
        guard let directory, let folder = folder(for: sessionId) else { return [] }
        let limit = maximumBytes
        return await queued(sessionId) { () -> [String]? in
            guard let attachments = Self.decode(list) else { return nil }
            return Self.write(attachments, to: folder, in: directory, limit: limit)
        }
    }

    /// Decodes and keeps an ordered draft off the main actor in the chat's existing write queue.
    /// Nil means the page sent a malformed draft; a valid draft with no writable directory still
    /// answers an empty held list, matching the attachment-only path.
    public func keepOrdered(_ value: JSONValue, for sessionId: String) async -> [String]? {
        let directory = self.directory
        let folder = folder(for: sessionId)
        let limit = maximumBytes
        return await queued(sessionId) {
            guard let draft = Self.decodeDraft(value) else { return nil }
            guard let directory, let folder else { return [] }
            return Self.write(draft.attachments, text: draft.text, ordered: true,
                              to: folder, in: directory, limit: limit)
        }
    }

    /// Keeps an ordered draft while retaining the old attachment-only storage API for older pages.
    public func keep(_ draft: AgentPaneDraft, for sessionId: String) async -> [String]? {
        guard let directory, let folder = folder(for: sessionId) else { return [] }
        let limit = maximumBytes
        return await queued(sessionId) {
            Self.write(draft.attachments, text: draft.text, ordered: true,
                       to: folder, in: directory, limit: limit)
        }
    }

    /// Runs `work` off the main actor after the chat's queued work.
    private func queued<T: Sendable>(_ sessionId: String, _ work: @escaping @Sendable () -> T) async -> T {
        let previous = queue[sessionId]
        let task = Task.detached { () -> T in
            await previous?.value
            return work()
        }
        let done = Task.detached { _ = await task.value }
        queue[sessionId] = done
        let value = await task.value
        if queue[sessionId] == done { queue[sessionId] = nil }
        return value
    }

    /// The page's chips from their JSON; nil when it is not a list of chips.
    nonisolated static func decode(_ list: JSONValue) -> [AgentPaneWakeState.Attachment]? {
        let object = list.foundationObject
        // A NaN or infinite number would raise, not throw.
        guard case .array = list, JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode([AgentPaneWakeState.Attachment].self, from: data)
    }

    /// Decodes the ordered `{text, attachments}` draft accepted by the newer page.
    nonisolated static func decodeDraft(_ value: JSONValue) -> AgentPaneDraft? {
        guard case .object = value, JSONSerialization.isValidJSONObject(value.foundationObject),
              let data = try? JSONSerialization.data(withJSONObject: value.foundationObject) else { return nil }
        return try? JSONDecoder().decode(AgentPaneDraft.self, from: data)
    }

    /// The chips as the page's JSON.
    nonisolated static func json(_ attachments: [AgentPaneWakeState.Attachment]) -> JSONValue {
        guard let data = try? JSONEncoder().encode(attachments),
              let object = try? JSONSerialization.jsonObject(with: data) else { return .array([]) }
        return JSONValue(foundation: object) ?? .array([])
    }

    /// Encodes an ordered draft for a page action response.
    nonisolated static func json(_ draft: AgentPaneDraft) -> JSONValue {
        guard let data = try? JSONEncoder().encode(draft),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return .object(["text": .string(""), "attachments": .array([])])
        }
        return JSONValue(foundation: object) ?? .object(["text": .string(""), "attachments": .array([])])
    }

    /// Chat `sessionId`'s folder: a digest of its id, so any id is a safe name.
    func folder(for sessionId: String) -> URL? {
        let digest = SHA256.hash(data: Data(sessionId.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory?.appending(path: String(digest.prefix(32)), directoryHint: .isDirectory)
    }

    /// One chat's kept list: the chips without their contents, and their files by attachment id.
    nonisolated struct Saved: Codable {
        var attachments: [AgentPaneWakeState.Attachment]
        var files: [String: String]?
        var text: String?

        init(attachments: [AgentPaneWakeState.Attachment], files: [String: String]? = nil, text: String? = nil) {
            self.attachments = attachments
            self.files = files
            self.text = text
        }
    }

    private nonisolated static func saved(in folder: URL) -> Saved? {
        // concurrency-allow: one small list file, read off the main actor
        guard let data = try? Data(contentsOf: folder.appending(path: listName)) else { return nil }
        return try? JSONDecoder().decode(Saved.self, from: data)
    }

    private nonisolated static func read(_ folder: URL, limit: Int) -> [AgentPaneWakeState.Attachment] {
        guard let saved = saved(in: folder) else { return [] }
        var budget = limit
        return AgentPaneAttachmentFiles.readBack(saved.attachments, files: saved.files ?? [:], in: folder, budget: &budget)
    }

    private nonisolated static func readDraft(_ folder: URL, limit: Int) -> AgentPaneDraft {
        guard let saved = saved(in: folder) else { return AgentPaneDraft() }
        var budget = limit
        let attachments = AgentPaneAttachmentFiles.readBack(saved.attachments, files: saved.files ?? [:], in: folder, budget: &budget)
        let text = repairMarks(saved.text ?? "", original: saved.attachments, restored: attachments)
        return AgentPaneDraft(text: text, attachments: attachments)
    }

    /// Removes marks for saved attachments whose bytes could not be restored, preserving the
    /// remaining attachment-to-mark mapping instead of shifting later thumbnails left.
    private nonisolated static func repairMarks(_ text: String,
                                                original: [AgentPaneWakeState.Attachment],
                                                restored: [AgentPaneWakeState.Attachment]) -> String {
        guard !original.isEmpty else { return text }
        var restoredIndices: [Int] = []
        var used = Set<Int>()
        for attachment in restored {
            guard let index = original.indices.first(where: { !used.contains($0) && original[$0].id == attachment.id }) else {
                continue
            }
            used.insert(index)
            restoredIndices.append(index)
        }
        let restoredSet = Set(restoredIndices)
        var output = String.UnicodeScalarView()
        var markIndex = 0
        for scalar in text.unicodeScalars {
            guard scalar == AgentPaneDraft.attachmentMark else {
                output.append(scalar)
                continue
            }
            // Extra marks are retained as malformed plain text; marks for known saved attachments
            // are retained only when that attachment survived the bounded file read.
            if markIndex >= original.count || restoredSet.contains(markIndex) {
                output.append(scalar)
            }
            markIndex += 1
        }
        return String(output)
    }

    private nonisolated static func write(_ attachments: [AgentPaneWakeState.Attachment], text: String? = nil,
                                          ordered: Bool = false,
                                          to folder: URL, in directory: URL, limit: Int) -> [String] {
        let manager = FileManager.default
        let previous = saved(in: folder)
        let kept = previous?.files ?? [:]
        let hasText = ordered && text?.isEmpty == false
        // A chat past the limit keeps nothing rather than some of its chips.
        guard (hasText || !attachments.isEmpty),
              let moved = AgentPaneAttachmentFiles.moveOut(attachments, to: folder, within: limit, kept: kept),
              (hasText || !moved.attachments.isEmpty) else {
            try? manager.removeItem(at: folder)
            return []
        }
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            let list = try JSONEncoder().encode(Saved(attachments: moved.attachments,
                                                      files: moved.files.isEmpty ? nil : moved.files,
                                                      text: hasText ? text : nil))
            try list.write(to: folder.appending(path: listName), options: .atomic)
        } catch {
            try? manager.removeItem(at: folder)
            return []
        }
        // Files no chip names any more (a chip taken out) go.
        let named = Set(moved.files.values).union([listName])
        for name in (try? manager.contentsOfDirectory(atPath: folder.path)) ?? [] where !named.contains(name) {
            try? manager.removeItem(at: folder.appending(path: name))
        }
        prune(directory)
        return moved.files.keys.sorted()
    }

    /// Only the ``limit`` most recently written chats stay.
    private nonisolated static func prune(_ directory: URL) {
        let manager = FileManager.default
        let folders = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        guard folders.count > limit else { return }
        let written = { (folder: URL) in
            (try? folder.appending(path: listName).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        }
        for folder in folders.sorted(by: { written($0) > written($1) }).dropFirst(limit) {
            try? manager.removeItem(at: folder)
        }
    }
}
