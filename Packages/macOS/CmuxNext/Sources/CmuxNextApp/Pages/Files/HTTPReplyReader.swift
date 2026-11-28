import CFNetwork
import Foundation

/// Reads one HTTP/1.0 reply for a remote markdown image (coordinator decision (c)): the system's
/// CFHTTPMessage parses the status line and the headers; the body is the bytes after them, up to
/// Content-Length, else up to the close. Refused: a header block over ``maximumHeaderBytes``, any
/// Transfer-Encoding or Content-Encoding (the request asked for neither), a repeated, conflicting
/// or malformed Content-Length, a status other than 200 or a redirect, a body over the cap (checked
/// while reading), a body shorter than its Content-Length at the close.
nonisolated struct HTTPReplyReader {
    nonisolated struct Refusal: Error, Equatable, CustomStringConvertible {
        let reason: String
        var description: String { reason }
    }

    static let maximumHeaderBytes = 16 * 1024
    static let redirects: Set<Int> = [301, 302, 303, 307, 308]

    let maximumBody: Int
    private let message = CFHTTPMessageCreateEmpty(nil, false).takeRetainedValue()
    /// The bytes received until the headers completed (at most 16 KB plus one read).
    private var raw = Data()
    private var head: (status: Int, headers: [String: String], length: Int?)?
    private var body = Data()

    init(maximumBody: Int) {
        self.maximumBody = maximumBody
    }

    /// Adds received bytes; true once the reply is complete (its Content-Length arrived), when the
    /// reader wants no more. Throws on a refusal.
    mutating func append(_ data: Data) throws(Refusal) -> Bool {
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
        let checked = try Self.checkHead(message, headerBlock: raw.prefix(headerBytes))
        if let length = checked.length, length > maximumBody { throw Refusal(reason: "Content-Length over the cap") }
        head = checked
        raw = Data()
        body = received
        return try checkBody(head?.length)
    }

    /// The reply at the close (or once complete).
    func finish() throws(Refusal) -> RemoteImageResponse {
        guard let head else { throw Refusal(reason: "no complete headers") }
        if let length = head.length {
            guard body.count >= length else { throw Refusal(reason: "body shorter than its Content-Length") }
            return RemoteImageResponse(status: head.status, headers: head.headers, body: body.prefix(length))
        }
        return RemoteImageResponse(status: head.status, headers: head.headers, body: body)
    }

    private func checkBody(_ length: Int?) throws(Refusal) -> Bool {
        if let length { return body.count >= length }
        guard body.count <= maximumBody else { throw Refusal(reason: "body over the cap") }
        return false
    }

    private static func checkHead(_ message: CFHTTPMessage, headerBlock: Data) throws(Refusal) -> (status: Int, headers: [String: String], length: Int?) {
        let status = CFHTTPMessageGetResponseStatusCode(message)
        guard status == 200 || redirects.contains(status) else { throw Refusal(reason: "status \(status)") }
        let fields = CFHTTPMessageCopyAllHeaderFields(message)?.takeRetainedValue() as? [String: String] ?? [:]
        var headers: [String: String] = [:]
        for (name, value) in fields { headers[name.lowercased()] = value }
        guard headers["transfer-encoding"] == nil else { throw Refusal(reason: "Transfer-Encoding") }
        guard headers["content-encoding"] == nil else { throw Refusal(reason: "Content-Encoding") }
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
