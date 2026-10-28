import CmuxNextCompat
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
/// The App's one store reaches each page's provider by init (``AgentPaneChatStores``).
@MainActor
public final class AgentPaneDraftAttachments {
    public static let directoryName = "agent-draft-attachments"
    nonisolated static let listName = "draft.json"
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
        return try? JSONDecoder().blockingDecode([AgentPaneWakeState.Attachment].self, from: data)
    }

    /// The chips as the page's JSON.
    nonisolated static func json(_ attachments: [AgentPaneWakeState.Attachment]) -> JSONValue {
        guard let data = try? JSONEncoder().encode(attachments),
              let object = try? JSONSerialization.blockingJSONObject(with: data) else { return .array([]) }
        return JSONValue(foundation: object) ?? .array([])
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
    }

    private nonisolated static func saved(in folder: URL) -> Saved? {
        // concurrency-allow: one small list file, read off the main actor
        guard let data = try? Data(contentsOf: folder.appending(path: listName)) else { return nil }
        return try? JSONDecoder().blockingDecode(Saved.self, from: data)
    }

    private nonisolated static func read(_ folder: URL, limit: Int) -> [AgentPaneWakeState.Attachment] {
        guard let saved = saved(in: folder) else { return [] }
        var budget = limit
        return AgentPaneAttachmentFiles.readBack(saved.attachments, files: saved.files ?? [:], in: folder, budget: &budget)
    }

    private nonisolated static func write(_ attachments: [AgentPaneWakeState.Attachment], to folder: URL, in directory: URL, limit: Int) -> [String] {
        let kept = saved(in: folder)?.files ?? [:]
        // A chat past the limit keeps nothing rather than some of its chips.
        guard !attachments.isEmpty, let moved = AgentPaneAttachmentFiles.moveOut(attachments, to: folder, within: limit, kept: kept),
              !moved.attachments.isEmpty else {
            try? FileManager.checked.removeItem(at: folder)
            return []
        }
        do {
            try FileManager.checked.createDirectory(at: folder, withIntermediateDirectories: true)
            let list = try JSONEncoder().encode(Saved(attachments: moved.attachments, files: moved.files.isEmpty ? nil : moved.files))
            try list.write(to: folder.appending(path: listName), options: .atomic)
        } catch {
            try? FileManager.checked.removeItem(at: folder)
            return []
        }
        // Files no chip names any more (a chip taken out) go.
        let named = Set(moved.files.values).union([listName])
        for name in (try? FileManager.checked.contentsOfDirectory(atPath: folder.path)) ?? [] where !named.contains(name) {
            try? FileManager.checked.removeItem(at: folder.appending(path: name))
        }
        prune(directory)
        return moved.files.keys.sorted()
    }

    /// Only the ``limit`` most recently written chats stay.
    private nonisolated static func prune(_ directory: URL) {
        let folders = (try? FileManager.checked.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        guard folders.count > limit else { return }
        let written = { (folder: URL) in
            (try? folder.appending(path: listName).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        }
        for folder in folders.sorted(by: { written($0) > written($1) }).dropFirst(limit) {
            try? FileManager.checked.removeItem(at: folder)
        }
    }
}
