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

    /// A disk failure is distinct from an empty draft. Callers reject the page operation and can
    /// retry it, while the last valid list and its files remain in place.
    nonisolated enum Failure: Error, Sendable, CustomStringConvertible {
        case read(URL)
        case write(URL)

        var description: String {
            switch self {
            case let .read(url): "could not read draft attachment \(url.path)"
            case let .write(url): "could not write draft attachment \(url.path)"
            }
        }
    }

    public init(directory: URL?) {
        self.directory = directory?.appending(path: Self.directoryName, directoryHint: .isDirectory)
    }

    /// The chips chat `sessionId` was left with, contents read back; empty when it holds none.
    public func attachments(for sessionId: String) async throws -> [AgentPaneWakeState.Attachment] {
        guard let folder = folder(for: sessionId) else { return [] }
        return try await queued(sessionId) { try Self.read(folder) }
    }

    /// Keeps `list` (the page's chips, as JSON) as chat `sessionId`'s chips; none forgets them. A
    /// chip sent without its contents keeps the file it already has. Answers the ids of the chips
    /// whose contents are kept, so the page knows which it need not send again; nil when `list` is
    /// not a list of chips. The list is decoded in the chat's queue, off the main actor.
    public func keep(_ list: JSONValue, for sessionId: String) async throws -> [String]? {
        guard let directory, let folder = folder(for: sessionId) else { return [] }
        return try await queued(sessionId) { () throws -> [String]? in
            guard let attachments = Self.decode(list) else { return nil }
            return try Self.write(attachments, to: folder, in: directory)
        }
    }

    /// Runs `work` off the main actor after the chat's queued work.
    private func queued<T: Sendable>(_ sessionId: String, _ work: @escaping @Sendable () throws -> T) async throws -> T {
        let previous = queue[sessionId]
        let task = Task.detached { () throws -> T in
            await previous?.value
            return try work()
        }
        let done = Task.detached { _ = await task.result }
        queue[sessionId] = done
        defer {
            if queue[sessionId] == done { queue[sessionId] = nil }
        }
        return try await task.value
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

    private nonisolated static func saved(in folder: URL) throws -> Saved? {
        let manager = FileManager.default
        do {
            // Listing distinguishes a genuinely absent folder from a folder that cannot be read.
            // `fileExists` reports both as false, which used to turn permission failures into an
            // empty draft.
            _ = try manager.contentsOfDirectory(atPath: folder.path)
        } catch CocoaError.fileNoSuchFile {
            return nil
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            throw Failure.read(folder)
        }
        let list = folder.appending(path: listName)
        do {
            // concurrency-allow: one small list file, read off the main actor
            let data = try Data(contentsOf: list)
            return try JSONDecoder().decode(Saved.self, from: data)
        } catch CocoaError.fileNoSuchFile {
            throw Failure.read(list)
        } catch CocoaError.fileReadNoSuchFile {
            throw Failure.read(list)
        } catch {
            throw Failure.read(list)
        }
    }

    private nonisolated static func read(_ folder: URL) throws -> [AgentPaneWakeState.Attachment] {
        guard let saved = try saved(in: folder) else { return [] }
        let bytes = try AgentPaneAttachmentFiles.readBackStrict(saved.attachments, files: saved.files ?? [:], in: folder)
        return try AgentPaneAttachmentFiles.readBackStrict(bytes, .text, files: saved.texts ?? [:], in: folder)
    }

    private nonisolated static func write(_ attachments: [AgentPaneWakeState.Attachment], to folder: URL, in directory: URL) throws -> [String] {
        let manager = FileManager.default
        // Empty is the page's explicit send/remove acknowledgement. Handle it before reading the
        // manifest so a missing old folder remains a successful no-op.
        if attachments.isEmpty {
            do {
                try manager.removeItem(at: folder)
            } catch CocoaError.fileNoSuchFile {
                return []
            } catch CocoaError.fileReadNoSuchFile {
                return []
            } catch {
                throw Failure.write(folder)
            }
            return []
        }

        let previous = try saved(in: folder)
        let kept = previous
        func removeUncommittedFiles() {
            let old = Set((kept?.files?.values.map { $0 } ?? []) + (kept?.texts?.values.map { $0 } ?? []) + [listName])
            for name in (try? manager.contentsOfDirectory(atPath: folder.path)) ?? [] where !old.contains(name) {
                try? manager.removeItem(at: folder.appending(path: name))
            }
        }
        // A chat whose chips' contents can't be kept (none sent and no file, or a file that can't be
        // written) keeps nothing rather than some of its chips. Bytes and text alike go to files of
        // their own, so the list holds only the chips' names and kinds.
        guard let bytes = AgentPaneAttachmentFiles.moveOut(attachments, to: folder, kept: kept?.files ?? [:], failOnMissingKept: true) else {
            if previous == nil { try? manager.removeItem(at: folder) }
            throw Failure.write(folder)
        }
        // A new image, document or recording without bytes has historically been ignored when it
        // was the first draft the host saw. Once a valid draft exists, silently dropping such a
        // chip would replace that draft with an incomplete list, so reject the whole replacement.
        let requested = Set(attachments.map(\.id))
        let retained = Set(bytes.attachments.map(\.id)).union(Set(bytes.files.keys))
        if previous != nil, !requested.isSubset(of: retained) {
            removeUncommittedFiles()
            throw Failure.write(folder)
        }
        guard let texts = AgentPaneAttachmentFiles.moveOut(bytes.attachments, .text, to: folder, kept: kept?.texts ?? [:], failOnMissingKept: true) else {
            removeUncommittedFiles()
            if previous == nil { try? manager.removeItem(at: folder) }
            throw Failure.write(folder)
        }
        guard !texts.attachments.isEmpty else {
            do {
                try manager.removeItem(at: folder)
                return []
            } catch {
                removeUncommittedFiles()
                throw Failure.write(folder)
            }
        }
        // The list is written last, atomically: one that fails (a full disk, a locked folder) leaves
        // the list before it and the files it names, never deletes them.
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            let list = try JSONEncoder().encode(Saved(attachments: texts.attachments, files: bytes.files.isEmpty ? nil : bytes.files,
                                                      texts: texts.files.isEmpty ? nil : texts.files))
            try list.write(to: folder.appending(path: listName), options: .atomic)
        } catch {
            removeUncommittedFiles()
            throw Failure.write(folder.appending(path: listName))
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
