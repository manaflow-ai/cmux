import Foundation

/// Failure modes of ``HTTPRequestParser``.
///
/// The transport layer (Phase 1 Task 1.10 router) maps these onto
/// HTTP status codes:
/// - ``malformedRequestLine``, ``malformedHeader``,
///   ``contentLengthInvalid`` → **400 Bad Request**.
/// - ``headerTooLarge`` → **431 Request Header Fields Too Large** at
///   the transport layer (parser only signals the cap was exceeded).
/// - ``bodyTooLarge`` → **413 Payload Too Large**, decided upfront
///   from `Content-Length` so the server never blocks reading body
///   bytes that would just be rejected anyway.
public enum HTTPParseError: Error, Equatable, Sendable {
    /// Request line missing, garbled, or not `METHOD TARGET HTTP/x.y`.
    case malformedRequestLine
    /// A header line was present but did not contain a `:`
    /// separator.
    case malformedHeader
    /// Aggregate header bytes exceeded `maxHeaderBytes`.
    case headerTooLarge
    /// `Content-Length` was missing, negative, non-numeric, or
    /// otherwise unparseable.
    case contentLengthInvalid
    /// `Content-Length` exceeded `maxBodyBytes`; rejected upfront.
    case bodyTooLarge
    /// `Transfer-Encoding` was present (chunked / compressed). Not
    /// supported in v1 — clients must send a known `Content-Length`.
    case transferEncodingUnsupported
    /// HTTP/1.1 request missing the mandatory `Host` header.
    case missingHost
}
