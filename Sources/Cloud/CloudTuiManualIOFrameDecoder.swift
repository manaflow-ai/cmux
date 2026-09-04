import CoreFoundation
import Foundation

/// Decodes one newline-delimited cmux-tui protocol message into a byte event.
///
/// The decoder is intentionally stateless. A socket reader owns line framing;
/// this value only validates the event discriminator and base64 payload.
struct CloudTuiManualIOFrameDecoder: Sendable {
    /// Decodes a complete JSON object line, returning `nil` for malformed or
    /// unrelated messages.
    func decode(_ line: Data) -> CloudTuiManualIOFrame? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return nil
        }
        if let event = object["event"] as? String {
            return decodeEvent(event, object: object)
        }
        guard let requestID = Self.uint64(object["id"]),
              let ok = object["ok"] as? Bool else {
            return nil
        }
        let responseData = object["data"] as? [String: Any]
        return .response(
            requestID: requestID,
            ok: ok,
            lease: (responseData?["lease"] as? String) ?? (object["lease"] as? String),
            capabilities: (responseData?["capabilities"] as? [String]) ?? [],
            outcome: responseData?["outcome"] as? String,
            accepted: responseData?["accepted"] as? Bool,
            error: object["error"] as? String
        )
    }

    private func decodeEvent(_ event: String, object: [String: Any]) -> CloudTuiManualIOFrame? {
        guard let surfaceID = Self.positiveUInt64(object["surface"]) else {
            if event == "overflow" { return .overflow(surfaceID: nil) }
            return nil
        }
        switch event {
        case "vt-state":
            guard let size = Self.size(from: object), let bytes = Self.bytes(from: object["data"]) else { return nil }
            return .snapshot(surfaceID: surfaceID, columns: size.columns, rows: size.rows, bytes: bytes)
        case "output":
            guard let bytes = Self.bytes(from: object["data"]) else { return nil }
            return .output(surfaceID: surfaceID, bytes: bytes)
        case "resized":
            guard let size = Self.size(from: object),
                  let bytes = Self.bytes(
                      from: (object["replay"] as? String) ?? (object["data"] as? String)
                  ) else { return nil }
            return .resized(surfaceID: surfaceID, columns: size.columns, rows: size.rows, bytes: bytes)
        case "detached":
            return .detached(surfaceID: surfaceID)
        case "overflow":
            return .overflow(surfaceID: surfaceID)
        default:
            return nil
        }
    }

    private static func size(from object: [String: Any]) -> (columns: Int, rows: Int)? {
        guard let columns = uint64(object["cols"]),
              let rows = uint64(object["rows"]),
              columns > 0,
              rows > 0,
              columns <= UInt64(Int.max),
              rows <= UInt64(Int.max) else {
            return nil
        }
        return (Int(columns), Int(rows))
    }

    private static func bytes(from value: Any?) -> Data? {
        guard let encoded = value as? String else { return nil }
        return Data(base64Encoded: encoded)
    }

    private static func uint64(_ value: Any?) -> UInt64? {
        if let number = value as? NSNumber {
            // JSON booleans bridge to NSNumber. Treating true as surface 1 or
            // request id 1 would route a frame to an unrelated attachment.
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let type = String(cString: number.objCType)
            switch type {
            case "c", "s", "i", "l", "q":
                let signed = number.int64Value
                return signed >= 0 ? UInt64(signed) : nil
            case "C", "S", "I", "L", "Q":
                return number.uint64Value
            // The wire schema uses JSON integers (`uint64`/`uint16`). Even an
            // exactly integral JSON float such as `1.0` is a different wire
            // type and must not be normalized into an identifier or grid.
            case "f", "d":
                return nil
            default:
                return nil
            }
        }
        if let string = value as? String {
            return UInt64(string)
        }
        return nil
    }

    private static func positiveUInt64(_ value: Any?) -> UInt64? {
        guard let value = uint64(value), value > 0 else { return nil }
        return value
    }
}
