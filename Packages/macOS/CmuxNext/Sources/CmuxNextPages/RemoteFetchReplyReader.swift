import CFNetwork
import Foundation

/// Reads one HTTP/1.1 reply of a pinned remote fetch: the system's CFHTTPMessage parses the status
/// line and the headers; the body is the bytes after them, de-chunked
/// (``RemoteFetchChunkedBody``) for `Transfer-Encoding: chunked`, else up to Content-Length, else
/// up to the close; then a `gzip`, `deflate` or `br` Content-Encoding is decoded
/// (``RemoteFetchContentDecoding``). Refused: a header block over ``maximumHeaderBytes``, a
/// Transfer-Encoding other than `chunked` or chunked together with Content-Length, a
/// Content-Encoding the request did not offer, a repeated, conflicting or malformed
/// Content-Length, a status other than 2xx or a redirect, a wire or decoded body over the cap
/// (checked while reading and while decoding), a body shorter than its Content-Length or a chunked
/// body without its last chunk at the close.
nonisolated struct RemoteFetchReplyReader {
    nonisolated struct Refusal: Error, Equatable, CustomStringConvertible {
        let reason: String
        /// The body (or its Content-Length) is over the fetch's cap.
        var overCap = false
        var description: String { reason }
    }

    static let maximumHeaderBytes = 16 * 1024
    static let redirects: Set<Int> = [301, 302, 303, 307, 308]

    let maximumBody: Int
    private var message = CFHTTPMessageCreateEmpty(nil, false).takeRetainedValue()
    /// Interim (1xx) replies skipped before the final one.
    private var interim = 0
    /// The bytes received until the headers completed (at most 16 KB plus one read).
    private var raw = Data()
    private var head: (status: Int, headers: [String: String], length: Int?)?
    private var body = Data()
    /// The de-chunker, used when the reply is chunked.
    private var isChunked = false
    private var chunked: RemoteFetchChunkedBody

    init(maximumBody: Int) {
        self.maximumBody = maximumBody
        chunked = RemoteFetchChunkedBody(maximumBody: maximumBody)
    }

    /// Adds received bytes; true once the reply is complete (its Content-Length arrived), when the
    /// reader wants no more. Throws on a refusal.
    mutating func append(_ data: Data) throws(Refusal) -> Bool {
        if isChunked { return try chunked.append(data) }
        if let head {
            body.append(data)
            return try checkBody(head.length)
        }
        raw.append(data)
        let accepted = data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return true }
            return CFHTTPMessageAppendBytes(message, base, buffer.count)
        }
        guard accepted else { throw Refusal(reason: "not an HTTP reply") }
        guard CFHTTPMessageIsHeaderComplete(message) else {
            if raw.count > Self.maximumHeaderBytes { throw Refusal(reason: "headers over 16 KB") }
            return false
        }
        let received = CFHTTPMessageCopyBody(message)?.takeRetainedValue() as Data? ?? Data()
        let headerBytes = raw.count - received.count
        guard headerBytes <= Self.maximumHeaderBytes else { throw Refusal(reason: "headers over 16 KB") }
        // An HTTP/1.1 server may send interim replies (100 Continue, 103 Early Hints) before the
        // final one: skip them and parse what follows as a new reply. 101 (a protocol switch) is
        // refused below.
        let status = CFHTTPMessageGetResponseStatusCode(message)
        if (100..<200).contains(status), status != 101 {
            interim += 1
            guard interim <= 4 else { throw Refusal(reason: "too many interim replies") }
            message = CFHTTPMessageCreateEmpty(nil, false).takeRetainedValue()
            raw = Data()
            return received.isEmpty ? false : try append(received)
        }
        let checked = try Self.checkHead(message, headerBlock: raw.prefix(headerBytes))
        if let length = checked.length, length > maximumBody { throw Refusal(reason: "Content-Length over the cap", overCap: true) }
        head = checked
        raw = Data()
        if checked.headers["transfer-encoding"] != nil {
            isChunked = true
            return try chunked.append(received)
        }
        body = received
        return try checkBody(head?.length)
    }

    /// The reply at the close (or once complete).
    func finish() throws(Refusal) -> RemoteFetchResponse {
        guard let head else { throw Refusal(reason: "no complete headers") }
        let wire: Data
        if isChunked {
            guard chunked.isComplete else { throw Refusal(reason: "chunked body without its last chunk") }
            wire = chunked.output
        } else if let length = head.length {
            guard body.count >= length else { throw Refusal(reason: "body shorter than its Content-Length") }
            wire = body.prefix(length)
        } else {
            wire = body
        }
        // A redirect's body is never used; decoding it could only fail the hop.
        let decoded = Self.redirects.contains(head.status)
            ? Data()
            : try RemoteFetchContentDecoding.decode(wire, encoding: head.headers["content-encoding"], maximumBody: maximumBody)
        return RemoteFetchResponse(status: head.status, headers: head.headers, body: decoded)
    }

    private func checkBody(_ length: Int?) throws(Refusal) -> Bool {
        if let length { return body.count >= length }
        guard body.count <= maximumBody else { throw Refusal(reason: "body over the cap", overCap: true) }
        return false
    }

    private static func checkHead(_ message: CFHTTPMessage, headerBlock: Data) throws(Refusal) -> (status: Int, headers: [String: String], length: Int?) {
        let status = CFHTTPMessageGetResponseStatusCode(message)
        guard (200..<300).contains(status) || redirects.contains(status) else { throw Refusal(reason: "status \(status)") }
        let fields = CFHTTPMessageCopyAllHeaderFields(message)?.takeRetainedValue() as? [String: String] ?? [:]
        var headers: [String: String] = [:]
        for (name, value) in fields { headers[name.lowercased()] = value }
        if let coding = headers["transfer-encoding"] {
            guard coding.trimmingCharacters(in: .whitespaces).lowercased() == "chunked" else { throw Refusal(reason: "Transfer-Encoding \(coding)") }
            // Both framings at once is the request-smuggling shape; refuse rather than pick one.
            guard headers["content-length"] == nil else { throw Refusal(reason: "chunked with Content-Length") }
        }
        if let coding = headers["content-encoding"] {
            guard ["identity", "gzip", "x-gzip", "deflate", "br"].contains(coding.trimmingCharacters(in: .whitespaces).lowercased()) else {
                throw Refusal(reason: "Content-Encoding \(coding)")
            }
        }
        // CFHTTPMessage keeps one value per name, so a repeated Content-Length is counted in the
        // header block itself (one field name, no parsing).
        let lines = String(decoding: headerBlock, as: UTF8.self).lowercased().components(separatedBy: "\r\n")
        guard lines.filter({ $0.hasPrefix("content-length:") }).count <= 1 else { throw Refusal(reason: "repeated Content-Length") }
        var length: Int?
        if let value = headers["content-length"] {
            let text = value.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, text.utf8.count <= 12, text.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
                  let parsed = Int(text) else { throw Refusal(reason: "Content-Length \(value)") }
            length = parsed
        }
        return (status, headers, length)
    }
}
