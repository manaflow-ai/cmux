public import Foundation

nonisolated extension RemoteRdHello {
    /// The rd cap for clipboard text sync (host and viewer apply each other's text while the
    /// viewer holds control).
    public static let clipboardTextCap = "clipboard.text"
}

extension RemoteRdStreamTransport: RemoteClipboardChannel {
    /// The host's clipboard texts, each complete, in order; one call per session (a new call
    /// finishes the previous stream). Texts that arrive with no subscriber are dropped.
    public func clipboardTexts() -> AsyncStream<String> {
        // concurrency-allow: a clipboard text is whole and rare; the bridge writes each to the pasteboard at once, and the newest wins
        let (stream, continuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingNewest(4))
        let previous = state.withLock { state in
            defer { state.clipboardTexts = continuation }
            return state.clipboardTexts
        }
        previous?.finish()
        return stream
    }

    /// Queues the viewer's clipboard text for the host. Nothing happens unless this session
    /// offered `clipboard.text` and the host listed it; the core drops a text the host has.
    public func offerClipboard(_ text: String) {
        queue.async { [self] in
            guard !engine.handshake.isEnded, let clipboard = engine.clipboard else { return }
            _ = try? clipboard.offer(text)
            pump()
        }
    }
}
