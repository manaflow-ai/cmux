import CmuxNextCompat
import Foundation

/// A long dictation recording sent to the machine a chat on another computer runs on (an ssh
/// peer's acpmux, a Cloud machine), so the chat's agent opens it there:
/// `dictation.recording.upload {path}` with the path the host gave the page
/// (``AgentPaneDictation/payload(_:)``).
///
/// Only a recording this pane's dictation wrote, in this chat, goes, and only once
/// (``AgentPaneDictation/takeRecording(_:session:)``); any other path the page names is refused
/// before anything is read. The file streams from disk through the chat's own upload stager
/// (``AgentPaneModel/onUploadStage``, the one a dropped file takes: `_acpmux/file_put` for a peer,
/// `cmux link access upload` for Cloud), one chunk in memory at a time, and the page gets where it
/// went on that machine. No gesture is asked: the bytes are the host's own recording, which the
/// person started in this pane, never something the page chose.
@MainActor
struct AgentPaneDictationUpload {
    /// The most one chunk carries; the App's stagers take this much (their `chunkSize`). The file is
    /// read off the main thread, a chunk at a time, while the person waits for the chip.
    static let chunkBytes = 512 * 1024

    static func respond(_ path: String, in model: AgentPaneModel) async -> [String: Any] {
        guard let stager = model.onUploadStage?(), let session = model.sessionId else {
            return AgentPaneModel.unsupported("dictation.recording.upload")
        }
        guard let file = model.onDictationRecording?(path, session) else {
            return AgentPaneReply.failure(code: "dictation.not_a_recording", message: "Not a recording this pane made.")
        }
        return await send(file, through: stager, session: session)
    }

    /// Streams `file` through `stager` for chat `session`: `{path}` on the chat's machine, or the
    /// stager's failure (a stage it began is cancelled, so it drops what it staged).
    static func send(_ file: URL, through stager: AgentPaneUploadStager, session: String) async -> [String: Any] {
        let failed = AgentPaneReply.failure(code: "upload_failed", message: "The recording could not be sent.")
        guard let size = await Task.detached(priority: .userInitiated, operation: { Self.size(of: file) }).value else { return failed }
        let begun = await stager(.begin(name: file.lastPathComponent, size: size, batchToken: nil, batch: nil), session)
        guard let started = value(begun) else { return begun }
        guard let token = started["token"] as? String else { return failed }
        guard let offered = started["chunkSize"] as? Int, offered > 0 else {
            _ = await stager(.cancel(token: token), session)
            return failed
        }
        let chunk = min(offered, chunkBytes)
        var offset = 0
        while offset < size {
            let at = offset, count = min(chunk, size - offset)
            let answer: [String: Any]
            if let bytes = await Task.detached(priority: .userInitiated, operation: { Self.read(file, at: at, count: count) }).value, bytes.count == count {
                answer = await stager(.chunk(token: token, offset: at, data: bytes), session)
            } else {
                answer = failed
            }
            guard value(answer)?["offset"] as? Int == at + count else {
                _ = await stager(.cancel(token: token), session)
                return value(answer) == nil ? answer : failed
            }
            offset += count
        }
        let finished = await stager(.finish(token: token), session)
        guard let reply = value(finished) else { return finished }
        guard let path = remotePath(reply) else { return failed }
        return AgentPaneReply.success(["path": path])
    }

    /// A success reply's value; nil for a failure.
    private static func value(_ reply: [String: Any]) -> [String: Any]? {
        reply["ok"] as? Bool == true ? (reply["value"] as? [String: Any] ?? [:]) : nil
    }

    /// The one path a stager's finish answers: a peer's `{path}`, Cloud's `{uploads: [{path}]}`.
    private static func remotePath(_ value: [String: Any]) -> String? {
        let paths = (value["path"] as? String).map { [$0] }
            ?? (value["uploads"] as? [[String: Any]])?.compactMap { $0["path"] as? String } ?? []
        guard paths.count == 1, let path = paths.first, path.hasPrefix("/") else { return nil }
        return path
    }

    /// The size of a regular file (not a link) at `file`; nil otherwise.
    nonisolated static func size(of file: URL) -> Int? {
        guard let attributes = try? FileManager.checked.attributesOfItem(atPath: file.path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
        return (attributes[.size] as? NSNumber)?.intValue
    }

    /// `count` bytes of `file` from `offset`; nil when it can't be read.
    nonisolated static func read(_ file: URL, at offset: Int, count: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(offset))
            return try handle.blockingRead(upToCount: count)
        } catch {
            return nil
        }
    }
}
