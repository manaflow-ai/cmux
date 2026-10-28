import CmuxNextCompat
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
/// person started in this pane, never something the page chose.
///
/// The page's `dictation.recording.cancel {path}` (the pending chip's ×) stops an upload while it
/// streams: ``cancel(_:in:)`` marks it, and the upload sees that before its next chunk, cancels the
/// stage and answers `cancelled`, which the page ignores. A cancel while the stager's finish runs
/// (the remote transfer, after the last chunk) cancels that finish's task, so the transfer stops
/// before it commits (Cloud's `cmux link access upload` child is killed); no stager can delete a
/// file it already committed, so one that commits anyway stays and its path is answered.
@MainActor
struct AgentPaneDictationUpload {
    /// The most one chunk carries; the App's stagers take this much (their `chunkSize`). The file is
    /// read off the main thread, a chunk at a time, while the person waits for the chip.
    static let chunkBytes = 512 * 1024

    /// One upload in flight (``AgentPaneModel/dictationUploads``): the chat it goes to, and whether
    /// the page cancelled it. Owned by its ``respond(_:in:)``, which adds and removes it.
    @MainActor
    final class Running {
        let session: String
        var cancelled = false
        /// The stager's finish while it runs, which a cancel cancels (``send(_:through:session:cancelled:finishing:)``).
        var finishing: Task<ResultBox, Never>?
        init(session: String) { self.session = session }

        /// The page cancelled: the upload stops at its next step, and a finish in flight is cancelled.
        func cancel() {
            cancelled = true
            finishing?.cancel()
        }
    }

    static func respond(_ path: String, in model: AgentPaneModel) async -> [String: Any] {
        guard let stager = model.onUploadStage?(), let session = model.sessionId else {
            return AgentPaneModel.unsupported("dictation.recording.upload")
        }
        guard let file = model.onDictationRecording?(path, session) else {
            return AgentPaneReply.failure(code: "dictation.not_a_recording", message: "Not a recording this pane made.")
        }
        // Taken once (above), so no other upload of this path runs; registered before any await, so
        // a cancel sent right after the upload finds it.
        let running = Running(session: session)
        model.dictationUploads[path] = running
        defer { if model.dictationUploads[path] === running { model.dictationUploads[path] = nil } }
        let reply = await send(file, through: stager, session: session, cancelled: { running.cancelled },
                               finishing: { running.finishing = $0 })
        // A failed upload gives the recording back, so the chip's Retry can send it again; a
        // cancelled one does not (the person removed it).
        if reply["ok"] as? Bool != true, !running.cancelled { model.onDictationRecordingUnsent?(file, session) }
        return reply
    }

    /// The page's cancel of the upload of `path`: refused unless this pane is sending it and still
    /// shows the chat it goes to (the chat whose recording it is). The upload stops at its next chunk.
    static func cancel(_ path: String, in model: AgentPaneModel) -> [String: Any] {
        guard let running = model.dictationUploads[path], running.session == model.sessionId else {
            return AgentPaneReply.failure(code: "dictation.not_uploading", message: "That recording is not being sent in this chat.")
        }
        running.cancel()
        return AgentPaneReply.success()
    }

    /// Streams `file` through `stager` for chat `session`: `{path}` on the chat's machine, or the
    /// stager's failure (a stage it began is cancelled, so it drops what it staged). `cancelled` is
    /// asked before each chunk and before the finish; once it says yes, nothing more is read, the
    /// stage is cancelled and the answer is `cancelled`. The finish runs in its own task, handed to
    /// `finishing` while it runs (nil once it ends), so a cancel can stop its transfer; a finish that
    /// a cancel stopped answers `cancelled`.
    static func send(
        _ file: URL,
        through stager: @escaping AgentPaneUploadStager,
        session: String,
        cancelled: () -> Bool = { false },
        finishing: (Task<ResultBox, Never>?) -> Void = { _ in }
    ) async -> [String: Any] {
        let failed = AgentPaneReply.failure(code: "upload_failed", message: "The recording could not be sent.")
        let stopped = AgentPaneReply.failure(code: "cancelled", message: "The recording's upload was stopped.")
        // Opened once, without following a link, and read only through that descriptor: a path
        // swapped for a symlink after this check never sends the file the link names.
        guard let opened = await Task.detached(priority: .userInitiated, operation: { Self.openRegular(file) }).value else { return failed }
        defer { try? opened.handle.close() }
        let size = opened.size
        if cancelled() { return stopped }
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
            if cancelled() {
                _ = await stager(.cancel(token: token), session)
                return stopped
            }
            let at = offset, count = min(chunk, size - offset)
            let answer: [String: Any]
            if let bytes = await Task.detached(priority: .userInitiated, operation: { Self.read(opened.handle, at: at, count: count) }).value, bytes.count == count {
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
            return stopped
        }
        // task-owner: this upload's finish, the one step the page's cancel must interrupt mid-await
        // (its remote transfer); awaited right below, held in Running.finishing only while it runs,
        // and cancelled by Running.cancel. No await separates the check above from here, so a cancel
        // either came before (answered above) or finds this task.
        let task = Task { @MainActor in ResultBox(await stager(.finish(token: token), session)) }
        finishing(task)
        // The request's own task cancelled (as before, when the finish ran in it) cancels it too.
        let finished = await withTaskCancellationHandler { await task.value.value } onCancel: { task.cancel() }
        finishing(nil)
        guard let reply = value(finished) else { return cancelled() ? stopped : finished }
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

    /// A recording opened for reading: its descriptor's handle and the size `fstat` gave it.
    // crash-allow: the handle is used by one upload, one awaited step at a time, never concurrently.
    nonisolated struct Opened: @unchecked Sendable {
        let handle: FileHandle
        let size: Int
    }

    /// `file` opened with `O_NOFOLLOW` (a symlink is refused) when that descriptor is a regular
    /// file; nil otherwise. Its checks and every read use the descriptor, never the path again.
    nonisolated static func openRegular(_ file: URL) -> Opened? {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            close(fd)
            return nil
        }
        return Opened(handle: FileHandle(fileDescriptor: fd, closeOnDealloc: true), size: Int(info.st_size))
    }

    /// `count` bytes of the opened recording from `offset`; nil when they can't be read.
    nonisolated static func read(_ handle: FileHandle, at offset: Int, count: Int) -> Data? {
        do {
            try handle.seek(toOffset: UInt64(offset))
            return try handle.blockingRead(upToCount: count)
        } catch {
            return nil
        }
    }
}
