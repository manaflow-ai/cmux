public import CmuxNextSettings
import CryptoKit
public import Foundation

/// Each agent chat's unsent composer chips (pasted screenshots, PDFs, files and folders), by
/// session, in ``directoryName`` beside the launch snapshot: one folder per chat with its chips'
/// list and their contents as files of their own. Leo 2026-10-20: a draft's text came back and its
/// pictures did not, after a quit, after reopening the chat and after restoring it from the archive.
/// acpmux keeps the text with the session; this keeps the chips, so every path that shows the chat
/// again (reopen, archive and restore, delete and restore, a relaunch or a crash) gets them back.
/// The page writes its chat's chips once they settle (`chat.draftAttachments`) and reads them when
/// the chat shows (`chat.draftAttachments.get`); sending or removing the last chip forgets them.
/// A chat's chips are kept whatever their size: attachments take arbitrarily large files of any
/// type (Leo 2026-10-26).
@MainActor
public final class AgentPaneDraftAttachments {
    public static let directoryName = "agent-draft-attachments"
    nonisolated static let listName = "draft.json"
    /// The app's store; nil keeps no chips (a test host, the gallery).
    public static var shared: AgentPaneDraftAttachments?
    /// The most recently written chats are kept.
    nonisolated static let limit = 100
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
        return await queued(sessionId) { Self.read(folder) }
    }

    /// Keeps `list` (the page's chips, as JSON) as chat `sessionId`'s chips; none forgets them. A
    /// chip sent without its contents keeps the file it already has. Answers the ids of the chips
    /// whose contents are kept, so the page knows which it need not send again; nil when `list` is
    /// not a list of chips. The list is decoded in the chat's queue, off the main actor.
    public func keep(_ list: JSONValue, for sessionId: String) async -> [String]? {
        guard let directory, let folder = folder(for: sessionId) else { return [] }
        return await queued(sessionId) { () -> [String]? in
            guard let attachments = Self.decode(list) else { return nil }
            return Self.write(attachments, to: folder, in: directory)
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

    /// The chips as the page's JSON.
    nonisolated static func json(_ attachments: [AgentPaneWakeState.Attachment]) -> JSONValue {
        guard let data = try? JSONEncoder().encode(attachments),
              let object = try? JSONSerialization.jsonObject(with: data) else { return .array([]) }
        return JSONValue(foundation: object) ?? .array([])
    }

    /// Chat `sessionId`'s folder: a digest of its id, so any id is a safe name.
    func folder(for sessionId: String) -> URL? {
        let digest = SHA256.hash(data: Data(sessionId.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory?.appending(path: String(digest.prefix(32)), directoryHint: .isDirectory)
    }

    /// One chat's kept list: the chips without their contents, and their files by attachment id. A
    /// list an older build wrote has no `texts`: its chips' text is inline and comes back as it is.
    nonisolated struct Saved: Codable {
        var attachments: [AgentPaneWakeState.Attachment]
        /// The file holding each chip's bytes (`data`), by attachment id.
        var files: [String: String]?
        /// The file holding each chip's text (a pasted chip's, a text file's), by attachment id.
        var texts: [String: String]?
    }

    private nonisolated static func saved(in folder: URL) -> Saved? {
        // concurrency-allow: one small list file, read off the main actor
        guard let data = try? Data(contentsOf: folder.appending(path: listName)) else { return nil }
        return try? JSONDecoder().decode(Saved.self, from: data)
    }

    private nonisolated static func read(_ folder: URL) -> [AgentPaneWakeState.Attachment] {
        guard let saved = saved(in: folder) else { return [] }
        let bytes = AgentPaneAttachmentFiles.readBack(saved.attachments, files: saved.files ?? [:], in: folder)
        return AgentPaneAttachmentFiles.readBack(bytes, .text, files: saved.texts ?? [:], in: folder)
    }

    private nonisolated static func write(_ attachments: [AgentPaneWakeState.Attachment], to folder: URL, in directory: URL) -> [String] {
        let manager = FileManager.default
        let kept = saved(in: folder)
        // A chat whose files can't be written keeps nothing rather than some of its chips. Bytes and
        // text alike go to files of their own, so the list holds only the chips' names and kinds.
        guard !attachments.isEmpty, let bytes = AgentPaneAttachmentFiles.moveOut(attachments, to: folder, kept: kept?.files ?? [:]),
              let texts = AgentPaneAttachmentFiles.moveOut(bytes.attachments, .text, to: folder, kept: kept?.texts ?? [:]),
              !texts.attachments.isEmpty else {
            try? manager.removeItem(at: folder)
            return []
        }
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            let list = try JSONEncoder().encode(Saved(attachments: texts.attachments, files: bytes.files.isEmpty ? nil : bytes.files,
                                                      texts: texts.files.isEmpty ? nil : texts.files))
            try list.write(to: folder.appending(path: listName), options: .atomic)
        } catch {
            try? manager.removeItem(at: folder)
            return []
        }
        // Files no chip names any more (a chip taken out) go.
        let named = Set(bytes.files.values).union(texts.files.values).union([listName])
        for name in (try? manager.contentsOfDirectory(atPath: folder.path)) ?? [] where !named.contains(name) {
            try? manager.removeItem(at: folder.appending(path: name))
        }
        prune(directory)
        return Set(bytes.files.keys).union(texts.files.keys).sorted()
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
