public import Foundation

/// Stateful incremental wrapper around ``RemoteLoopbackHTTPRequestRewriter``:
/// buffers request bytes until the header block is complete (or a size/EOF
/// limit is hit), rewrites once, then passes every later chunk through
/// untouched.
public struct RemoteLoopbackHTTPRequestStreamRewriter: Sendable {
    private static let maxHeaderBytes = 64 * 1024
    private static let headerDelimiter = Data([0x0D, 0x0A, 0x0D, 0x0A])

    private let aliasHost: String
    private var pendingHeaderBytes = Data()
    private var hasForwardedHeaders = false

    /// Creates a rewriter that maps `aliasHost` (and its subdomains) back to
    /// the localhost family.
    public init(aliasHost: String) {
        self.aliasHost = aliasHost
    }

    /// Feeds the next chunk from the client; returns the bytes to forward to
    /// the remote (empty while headers are still buffering).
    public mutating func rewriteNextChunk(_ data: Data, eof: Bool) -> Data {
        guard !hasForwardedHeaders else { return data }

        pendingHeaderBytes.append(data)
        if pendingHeaderBytes.count > Self.maxHeaderBytes {
            hasForwardedHeaders = true
            let payload = pendingHeaderBytes
            pendingHeaderBytes = Data()
            return RemoteLoopbackHTTPRequestRewriter.rewriteIfNeeded(
                data: payload,
                aliasHost: aliasHost,
                allowIncompleteHeadersAtEOF: true
            )
        }

        guard pendingHeaderBytes.range(of: Self.headerDelimiter) != nil else {
            guard eof else { return Data() }
            hasForwardedHeaders = true
            let payload = pendingHeaderBytes
            pendingHeaderBytes = Data()
            return RemoteLoopbackHTTPRequestRewriter.rewriteIfNeeded(
                data: payload,
                aliasHost: aliasHost,
                allowIncompleteHeadersAtEOF: true
            )
        }

        hasForwardedHeaders = true
        let payload = pendingHeaderBytes
        pendingHeaderBytes = Data()
        return RemoteLoopbackHTTPRequestRewriter.rewriteIfNeeded(
            data: payload,
            aliasHost: aliasHost
        )
    }
}
