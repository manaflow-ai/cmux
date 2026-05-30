import Foundation

/// Streaming HTTP/1.1 request parser for cmux control endpoints.
///
/// Designed for the loopback control transport, not a general-purpose
/// HTTP stack:
/// - Rejects oversized headers or bodies **up front** so a hostile
///   client cannot pin a connection by advertising a huge
///   `Content-Length` and never sending bytes (resolves the Phase 1
///   coverage must-fix where `oversizedBodyReturns413` would hang).
/// - Rejects `Transfer-Encoding` (chunked / compressed) in v1; the
///   server only accepts requests with a known `Content-Length`.
/// - HTTP/1.1 requests must carry a `Host` header (RFC 7230 §5.4).
///
/// One request per ``next()`` call. After a successful parse the
/// consumed bytes are removed from the internal buffer so subsequent
/// requests on the same connection can be parsed without
/// reconstruction.
///
/// ```swift
/// var parser = HTTPRequestParser(maxHeaderBytes: 16 * 1024, maxBodyBytes: 1 << 20)
/// parser.feed(socketBytes)
/// switch try parser.next() {
/// case .need: // read more bytes
/// case .complete(let request): handle(request)
/// }
/// ```
public struct HTTPRequestParser {
    /// Outcome of a single ``next()`` poll.
    public enum Outcome: Equatable {
        /// The current buffer doesn't yet hold a complete request.
        case need
        /// A request has been fully parsed and removed from the
        /// buffer.
        case complete(HTTPRequest)
    }

    private var buffer = Data()
    private let maxHeaderBytes: Int
    private let maxBodyBytes: Int

    /// Creates a parser with explicit caps.
    ///
    /// - Parameters:
    ///   - maxHeaderBytes: Hard cap on the size of the request line
    ///     plus headers (typically 16 KiB).
    ///   - maxBodyBytes: Hard cap on `Content-Length` (typically
    ///     1 MiB per spec §6.2).
    public init(maxHeaderBytes: Int, maxBodyBytes: Int) {
        self.maxHeaderBytes = maxHeaderBytes
        self.maxBodyBytes = maxBodyBytes
    }

    /// Appends socket bytes to the internal buffer. Callers feed
    /// however much data is available, then call ``next()``.
    public mutating func feed(_ data: Data) {
        buffer.append(data)
    }

    /// Attempts to parse one request from the buffered bytes.
    ///
    /// - Returns: ``Outcome/complete(_:)`` with the parsed request
    ///   (consuming its bytes from the buffer) or ``Outcome/need``
    ///   when more data is required.
    /// - Throws: ``HTTPParseError`` for any malformed input or cap
    ///   violation. The connection should be closed after the error
    ///   is mapped to a response.
    public mutating func next() throws -> Outcome {
        guard let headerEnd = findHeaderEnd(buffer) else {
            if buffer.count > maxHeaderBytes {
                throw HTTPParseError.headerTooLarge
            }
            return .need
        }
        if headerEnd > maxHeaderBytes {
            throw HTTPParseError.headerTooLarge
        }
        let headerBytes = buffer.prefix(headerEnd)
        guard let headerText = String(data: headerBytes, encoding: .utf8) else {
            throw HTTPParseError.malformedRequestLine
        }
        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else {
            throw HTTPParseError.malformedRequestLine
        }
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(
            separator: " ",
            maxSplits: 2,
            omittingEmptySubsequences: false
        )
        guard
            parts.count == 3,
            !parts[0].isEmpty,
            !parts[1].isEmpty,
            parts[2].hasPrefix("HTTP/")
        else {
            throw HTTPParseError.malformedRequestLine
        }
        let method = String(parts[0])
        let target = String(parts[1])
        let httpVersion = String(parts[2])
        let (path, query) = Self.splitTarget(target)

        var headers: [(String, String)] = []
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                throw HTTPParseError.malformedHeader
            }
            let name = line[..<colon]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            if name.isEmpty { throw HTTPParseError.malformedHeader }
            headers.append((name, value))
        }

        // v1 does not support chunked or compressed transfer encodings.
        if headers.contains(where: { $0.0 == "transfer-encoding" }) {
            throw HTTPParseError.transferEncodingUnsupported
        }

        // RFC 7230 §5.4: HTTP/1.1 requests MUST include Host.
        if httpVersion == "HTTP/1.1",
           headers.first(where: { $0.0 == "host" }) == nil {
            throw HTTPParseError.missingHost
        }

        let contentLength: Int
        if let raw = headers.first(where: { $0.0 == "content-length" })?.1 {
            guard let n = Int(raw), n >= 0 else {
                throw HTTPParseError.contentLengthInvalid
            }
            contentLength = n
        } else {
            contentLength = 0
        }
        // Reject upfront so we never block waiting for body bytes
        // that would only be discarded.
        if contentLength > maxBodyBytes {
            throw HTTPParseError.bodyTooLarge
        }

        let bodyStart = headerEnd + 4 // skip \r\n\r\n
        guard buffer.count >= bodyStart + contentLength else {
            return .need
        }
        let body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
        buffer.removeSubrange(0..<(bodyStart + contentLength))

        return .complete(HTTPRequest(
            method: method,
            path: path,
            query: query,
            headers: headers,
            body: body
        ))
    }

    private func findHeaderEnd(_ data: Data) -> Int? {
        if data.count < 4 { return nil }
        return data.withUnsafeBytes { raw -> Int? in
            let bytes = raw.bindMemory(to: UInt8.self)
            var i = 0
            let end = bytes.count - 3
            while i < end {
                if bytes[i] == 0x0D
                    && bytes[i + 1] == 0x0A
                    && bytes[i + 2] == 0x0D
                    && bytes[i + 3] == 0x0A
                {
                    return i
                }
                i += 1
            }
            return nil
        }
    }

    private static func splitTarget(_ target: String) -> (String, [String: String]) {
        guard let q = target.firstIndex(of: "?") else {
            return (target, [:])
        }
        let path = String(target[..<q])
        var out: [String: String] = [:]
        let rawQuery = target[target.index(after: q)...]
        for pair in rawQuery.split(separator: "&", omittingEmptySubsequences: true) {
            let kv = pair.split(separator: "=", maxSplits: 1)
            let rawKey = String(kv[0])
            let key = rawKey.removingPercentEncoding ?? rawKey
            let value: String
            if kv.count == 2 {
                let rawValue = String(kv[1])
                value = rawValue.removingPercentEncoding ?? rawValue
            } else {
                value = ""
            }
            out[key] = value
        }
        return (path, out)
    }
}
