import CmuxNextCompat
import CmuxNextDictation
import Darwin
import Foundation

/// A long dictation recording sent to the machine a chat on another computer runs on (an ssh
/// peer's acpmux, a Cloud machine), so the chat's agent opens it there:
/// `dictation.recording.upload {path}` with the path the host gave the page
/// (``AgentPaneDictation/payload(_:)``).
///
/// Only a recording this pane's dictation wrote, in this chat, goes, and only once
/// per try (``AgentPaneDictation/takeRecording(_:session:)``; a failed upload gives it back for the
/// page's Retry); any other path the page names is refused
/// before anything is read. The file streams from disk through the chat's own upload stager
/// (``AgentPaneModel/onUploadStage``, the one a dropped file takes: `_acpmux/file_put` for a peer,
/// `cmux link access upload` for Cloud), one chunk in memory at a time, and the page gets where it
/// went on that machine. No gesture is asked: the bytes are the host's own recording, which the
/// person started in this pane, never something the page chose. The chip's ×
/// (`dictation.recording.cancel {path}`) stops it before its next chunk and cancels the stage.
@MainActor
struct AgentPaneDictationUpload {
    /// The most one chunk carries; the App's stagers take this much (their `chunkSize`). The file is
    /// read off the main thread, a chunk at a time, while the person waits for the chip.
    static let chunkBytes = 512 * 1024

    static func respond(_ path: String, in model: AgentPaneModel) async -> [String: Any] {
        guard let stager = model.onUploadStage?(), let session = model.sessionId else {
            return AgentPaneModel.unsupported("dictation.recording.upload")
        }
        guard let recording = model.onDictationRecording?(path, session) else {
            return AgentPaneReply.failure(code: "dictation.not_a_recording", message: "Not a recording this pane made.")
        }
        model.dictationUploads.running.insert(path)
        defer {
            model.dictationUploads.running.remove(path)
            model.dictationUploads.cancelled.remove(path)
        }
        let reply = await send(recording, through: stager, session: session) { model.dictationUploads.cancelled.contains(path) }
        // A failed upload gives the recording back, so the chip's Retry can send it again.
        if reply["ok"] as? Bool != true { model.onDictationRecordingUnsent?(recording, session) }
        return reply
    }

    /// The chip's ×: the upload of `path` running now stops before its next chunk. Nothing else
    /// changes (a path not uploading is left alone).
    static func cancel(_ path: String, in model: AgentPaneModel) -> [String: Any] {
        if model.dictationUploads.running.contains(path) { model.dictationUploads.cancelled.insert(path) }
        return AgentPaneReply.success()
    }

    /// Streams `recording` through `stager` for chat `session`: `{path}` on the chat's machine, or
    /// the stager's failure (a stage it began is cancelled, so it drops what it staged). The file
    /// is opened once, and only when it is still the file the recording wrote (its identity; not a
    /// link, nor a file put at that path since); every chunk is read from that descriptor.
    /// `cancelled` (the chip's ×) is checked before each chunk and before the finish.
    static func send(
        _ recording: AgentPaneIssuedRecording,
        through stager: AgentPaneUploadStager,
        session: String,
        cancelled: () -> Bool = { false }
    ) async -> [String: Any] {
        let failed = AgentPaneReply.failure(code: "upload_failed", message: "The recording could not be sent.")
        guard let opened = await Task.detached(priority: .userInitiated, operation: { Recording.open(recording) }).value else { return failed }
        defer { opened.close() }
        let size = opened.size
        let begun = await stager(.begin(name: recording.file.lastPathComponent, size: size, batchToken: nil, batch: nil), session)
        guard let started = value(begun) else { return begun }
        // A begin that names no token gives nothing to cancel by; the stagers expire a stage left behind.
        guard let token = started["token"] as? String else { return failed }
        guard let offered = started["chunkSize"] as? Int, offered > 0 else {
            _ = await stager(.cancel(token: token), session)
            return failed
        }
        let chunk = min(offered, chunkBytes)
        var offset = 0
        while offset < size {
            if cancelled() {
                _ = await stager(.cancel(token: token), session)
                return AgentPaneReply.failure(code: "cancelled", message: "The recording was not sent.")
            }
            let at = offset, count = min(chunk, size - offset)
            let answer: [String: Any]
            if let bytes = await Task.detached(priority: .userInitiated, operation: { opened.read(at: at, count: count) }).value, bytes.count == count {
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
        if cancelled() {
            _ = await stager(.cancel(token: token), session)
            return AgentPaneReply.failure(code: "cancelled", message: "The recording was not sent.")
        }
        let finished = await stager(.finish(token: token), session)
        // A finish that failed, or answered no one path, may leave the stage behind: it is dropped.
        guard let path = value(finished).flatMap(remotePath) else {
            _ = await stager(.cancel(token: token), session)
            return value(finished) == nil ? finished : failed
        }
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

    /// A recording opened once for its upload: the regular file the recording wrote (not a link,
    /// not a FIFO, not another file put at its path), read through this one descriptor, so its path
    /// can't be swapped for another file between chunks either.
    nonisolated struct Recording: Sendable {
        let size: Int
        private let handle: FileHandle

        static func open(_ recording: AgentPaneIssuedRecording) -> Self? {
            let descriptor = Darwin.open(recording.file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { return nil }
            var info = stat()
            guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  DictationFileIdentity.of(descriptor: descriptor) == recording.identity else {
                Darwin.close(descriptor)
                return nil
            }
            return Self(size: Int(info.st_size), handle: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true))
        }

        /// `count` bytes from `offset`; nil when they can't be read.
        func read(at offset: Int, count: Int) -> Data? {
            do {
                try handle.seek(toOffset: UInt64(offset))
                return try handle.blockingRead(upToCount: count)
            } catch {
                return nil
            }
        }

        func close() {
            try? handle.close()
        }
    }
}

/// A long recording the pane's dictation handed the page: its file, and which file that was when
/// the recording closed it (``DictationAudio/fileIdentity``).
nonisolated struct AgentPaneIssuedRecording: Equatable, Sendable {
    let file: URL
    let identity: DictationFileIdentity
}

/// The recording uploads a pane runs now, by path, and the ones its page cancelled
/// (``AgentPaneDictationUpload/cancel(_:in:)``).
struct AgentPaneDictationUploads {
    var running: Set<String> = []
    var cancelled: Set<String> = []
}
