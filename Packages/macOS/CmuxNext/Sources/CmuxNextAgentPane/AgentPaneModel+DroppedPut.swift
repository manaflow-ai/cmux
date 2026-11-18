public import Foundation

/// What the App answers for one dropped file it put on a chat's machine from its path on this Mac
/// (``AgentPanePathPutter``): where it went there, or why it did not.
public nonisolated enum AgentPanePathPutReply: Sendable, Equatable {
    case path(String)
    case failure(code: String, message: String)
}

/// The App's put of the file at `file` (the person's own native drop on this Mac) on the machine
/// that runs chat session `sessionId`: an ssh peer's acpmux (`_acpmux/file_put*`, streamed from the
/// file) or a Cloud machine (`cmux link access upload` of the path). It runs off the main actor and
/// reads the file once; nothing crosses the page bridge.
public typealias AgentPanePathPutter = @MainActor (_ file: URL, _ sessionId: String) async -> AgentPanePathPutReply

extension AgentPaneModel {
    /// `chat.upload.begin {name, size, batchToken}` whose token is one this pane pushed with a native
    /// drop on a chat on another machine (``AgentPaneDroppedPaths/pushed(local:)``): the App puts that
    /// file there straight from its path, and this answers `{path}` once it is there. The page shows
    /// the chip at once and a send waits for this only to deliver the file. Each token answers once,
    /// only for the file it was made for; it needs no gesture, since only the person's own drop makes one.
    func putDropped(token: String, name: String) async -> [String: Any] {
        guard let file = droppedPaths.takePut(token, name: name) else {
            return AgentPaneReply.failure(code: "upload_failed", message: "The file could not be sent.")
        }
        // No App put for this chat (a chat on this Mac, an older App): the page sends the bytes.
        guard let session = sessionId, let put = onPathPut?() else { return Self.unsupported("chat.upload.path") }
        // task-owner: one put per pushed token, held in `droppedPaths.puts` so the tile's x
        // (`chat.upload.cancel`) or a session change cancels it, and awaited right here.
        let task = Task { await put(file, session) }
        droppedPaths.puts[token] = task
        let reply = await task.value
        droppedPaths.puts[token] = nil
        if task.isCancelled { return AgentPaneReply.failure(code: "cancelled", message: "The file could not be sent.") }
        switch reply {
        case .path(let path): return AgentPaneReply.success(["path": path])
        case .failure(let code, let message): return AgentPaneReply.failure(code: code, message: message)
        }
    }

    /// `chat.upload.cancel {token}` for a put under way (``putDropped(token:name:)``): it stops.
    func cancelDroppedPut(_ token: String) -> [String: Any] {
        droppedPaths.puts.removeValue(forKey: token)?.cancel()
        return AgentPaneReply.success()
    }
}
