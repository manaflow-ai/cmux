import CmuxNextCompat
import Foundation

/// Reads a dropped file a slice at a time, off the main actor.
private actor AgentPaneDroppedFileReader {
    private let handle: FileHandle

    init?(_ file: URL) {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        self.handle = handle
    }

    func read(_ count: Int) -> Data? {
        try? handle.blockingRead(upToCount: count)
    }

    func close() {
        try? handle.close()
    }

    /// The size of the regular file at `file`; nil for a folder or a file that is not there.
    nonisolated static func size(_ file: URL) -> Int? {
        guard let values = try? file.blockingResourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true else { return nil }
        return values.fileSize
    }
}

/// The answer a put of a dropped file gets, held for its awaiting request.
@MainActor
private final class AgentPaneDroppedPutAnswer {
    var reply: [String: Any] = AgentPaneReply.failure(code: "cancelled", message: "The file could not be sent.")
}

extension AgentPaneModel {
    /// Whether a native drop's files go to the page as this Mac's paths (``AgentPaneDroppedPaths/pushed(local:)``).
    /// Before its handshake a page on a remote route still reads `remoteChat == false` (the handshake
    /// sets it), so a drop then is never local: it streams from its path instead, and this Mac's
    /// path never reaches another machine (review F1 on #45756).
    var dropsGoAsLocalPaths: Bool {
        hasHandshake && !remoteChat && onLocalPaths?() == true
    }

    /// `chat.upload.begin {name, size, batchToken}` whose token is one this pane pushed with a native
    /// drop on a chat on another machine (``AgentPaneDroppedPaths/pushed(local:)``): the host sends
    /// that file to the chat's machine straight from its path, through the chat's own staged upload
    /// (``onUploadStage``: an ssh peer's `_acpmux/file_put*`, a Cloud machine's
    /// `cmux link access upload`), and answers as its finish does once it is there. The file is read
    /// off the main actor, a slice at a time; no byte crosses the page bridge or is base64 encoded
    /// for it. The page shows the chip at once and a send waits for this only to deliver the file.
    /// Each token answers once, only for the file it was made for; only the person's own drop makes one.
    func putDropped(token: String, name: String) async -> [String: Any] {
        guard let file = droppedPaths.takePut(token, name: name) else {
            return AgentPaneReply.failure(code: "upload_failed", message: "The file could not be sent.")
        }
        // No staged upload for this chat (an older App): the page sends the bytes.
        guard let stager = onUploadStage?() else { return Self.unsupported("chat.upload.path") }
        let session = sessionId
        let answer = AgentPaneDroppedPutAnswer()
        // task-owner: one put per pushed token, held in `droppedPaths.puts` so the tile's x
        // (`chat.upload.cancel`) or a session change cancels it, and awaited right here.
        let task = Task { answer.reply = await Self.stage(file, name: name, stager: stager, session: session) }
        droppedPaths.puts[token] = task
        await task.value
        if droppedPaths.puts[token] == task { droppedPaths.puts[token] = nil }
        return answer.reply
    }

    /// `chat.upload.cancel {token}` for a put under way (``putDropped(token:name:)``): it stops, and
    /// the chat's stage is dropped.
    func cancelDroppedPut(_ token: String) -> [String: Any] {
        droppedPaths.puts.removeValue(forKey: token)?.cancel()
        return AgentPaneReply.success()
    }

    /// `file` through `stager`: begin, each slice read off the main actor, finish. A cancel drops the stage.
    private static func stage(_ file: URL, name: String, stager: AgentPaneUploadStager, session: String?) async -> [String: Any] {
        let failed = AgentPaneReply.failure(code: "upload_failed", message: "The file could not be sent.")
        guard let size = await Task.detached(priority: .userInitiated, operation: { AgentPaneDroppedFileReader.size(file) }).value,
              let reader = AgentPaneDroppedFileReader(file) else { return failed }
        let begun = await stager(.begin(name: name, size: size, batchToken: nil, batch: nil), session)
        guard begun["ok"] as? Bool == true, let value = begun["value"] as? [String: Any],
              let token = value["token"] as? String,
              let chunk = (value["chunkSize"] as? NSNumber)?.intValue, chunk > 0 else {
            await reader.close()
            return begun["ok"] as? Bool == false ? begun : failed
        }
        var offset = 0
        var refusal: [String: Any]?
        while offset < size {
            if Task.isCancelled { break }
            guard let data = await reader.read(min(chunk, size - offset)), !data.isEmpty else {
                refusal = failed
                break
            }
            let answer = await stager(.chunk(token: token, offset: offset, data: AgentPaneUploadChunk(data)), session)
            guard answer["ok"] as? Bool == true,
                  ((answer["value"] as? [String: Any])?["offset"] as? NSNumber)?.intValue == offset + data.count else {
                refusal = answer["ok"] as? Bool == false ? answer : failed
                break
            }
            offset += data.count
        }
        await reader.close()
        guard refusal == nil, !Task.isCancelled else {
            _ = await stager(.cancel(token: token), session)
            return refusal ?? AgentPaneReply.failure(code: "cancelled", message: "The file could not be sent.")
        }
        return await stager(.finish(token: token), session)
    }
}
