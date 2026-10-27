/// Why a pinned fetch refused a reply: its framing, head or body broke a rule of
/// ``RemoteFetchReplyReader``, ``RemoteFetchChunkedBody`` or ``RemoteFetchContentDecoding``.
nonisolated struct RemoteFetchRefusal: Error, Equatable, CustomStringConvertible {
    let reason: String
    /// The body (or its Content-Length) is over the fetch's cap.
    var overCap = false
    var description: String { reason }
}
