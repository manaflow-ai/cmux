public import Foundation

// The decoder and the errors of the daemon event decode path (WireEventSet.swift, p05-ipc task 022).

/// Decodes one JSON value. The connection's decoder counts each call, so a test or the wire
/// stats see every parse of a line.
public protocol WireEventDecoding {
    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T
}

extension JSONDecoder: WireEventDecoding {}

/// Why an event line or TYPED_EVENT payload did not decode.
public enum WireEventDecodeError: Error, Equatable, Sendable {
    /// The line has no top-level string `event`, so nothing names the event.
    case noEventName(reason: String)
    /// The payload of a known event does not match its type.
    case payload(event: String, reason: String)
}
