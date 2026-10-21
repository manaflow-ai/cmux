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
    /// Each chat's write in flight: the next write and a read wait for it.
    private var writes: [String: Task<Void, Never>] = [:]

    public init(directory: URL?) {
        self.directory = directory?.appending(path: Self.directoryName, directoryHint: .isDirectory)
    }

    /// The chips chat `sessionId` was left with, contents read back; empty when it holds none.
    public func attachments(for sessionId: String) async -> [AgentPaneWakeState.Attachment] {
        guard let folder = folder(for: sessionId) else { return [] }
        await writes[sessionId]?.value
        let limit = maximumBytes
        return await Task.detached { Self.read(folder, limit: limit) }.value
    }

    /// Keeps `attachments` as chat `sessionId`'s chips; none forgets them. A chip sent without its
    /// contents keeps the file it already has.
    public func keep(_ attachments: [AgentPaneWakeState.Attachment], for sessionId: String) async {
        guard let directory, let folder = folder(for: sessionId) else { return }
        let previous = writes[sessionId]
        let limit = maximumBytes
        let write = Task.detached {
            await previous?.value
            Self.write(attachments, to: folder, in: directory, limit: limit)
        }
        writes[sessionId] = write
        await write.value
        if writes[sessionId] == write { writes[sessionId] = nil }
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
        return try? JSONDecoder().decode(Saved.self, from: data)
    }

    private nonisolated static func read(_ folder: URL, limit: Int) -> [AgentPaneWakeState.Attachment] {
        guard let saved = saved(in: folder) else { return [] }
        var budget = limit
        return AgentPaneAttachmentFiles.readBack(saved.attachments, files: saved.files ?? [:], in: folder, budget: &budget)
    }

    private nonisolated static func write(_ attachments: [AgentPaneWakeState.Attachment], to folder: URL, in directory: URL, limit: Int) {
        let manager = FileManager.default
        let kept = saved(in: folder)?.files ?? [:]
        // A chat past the limit keeps nothing rather than some of its chips.
        guard !attachments.isEmpty, let moved = AgentPaneAttachmentFiles.moveOut(attachments, to: folder, within: limit, kept: kept),
              !moved.attachments.isEmpty else {
            try? manager.removeItem(at: folder)
            return
        }
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            let list = try JSONEncoder().encode(Saved(attachments: moved.attachments, files: moved.files.isEmpty ? nil : moved.files))
            try list.write(to: folder.appending(path: listName), options: .atomic)
        } catch {
            try? manager.removeItem(at: folder)
            return
        }
        // Files no chip names any more (a chip taken out) go.
        let named = Set(moved.files.values).union([listName])
        for name in (try? manager.contentsOfDirectory(atPath: folder.path)) ?? [] where !named.contains(name) {
            try? manager.removeItem(at: folder.appending(path: name))
        }
        prune(directory)
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
