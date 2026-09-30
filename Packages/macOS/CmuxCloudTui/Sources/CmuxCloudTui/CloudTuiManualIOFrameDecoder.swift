import CmuxTerminalSizing
import CoreFoundation
import Foundation

/// Decodes one newline-delimited cmux-tui protocol message into a byte event.
///
/// The decoder is intentionally stateless. A socket reader owns line framing;
/// this value only validates the event discriminator and base64 payload.
public struct CloudTuiManualIOFrameDecoder: Sendable {
    public init() {}

    /// Decodes a complete JSON object line, returning `nil` for malformed or
    /// unrelated messages.
    public func decode(_ line: Data) -> CloudTuiManualIOFrame? {
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
            error: object["error"] as? String,
            sizing: Self.sizingResponse(from: responseData)
        )
    }

    private func decodeEvent(_ event: String, object: [String: Any]) -> CloudTuiManualIOFrame? {
        guard let surfaceID = Self.positiveUInt64(object["surface"]) else {
            if event == "overflow" { return .overflow(surfaceID: nil) }
            return nil
        }
        switch event {
        case "vt-state":
            guard let size = Self.size(from: object),
                  let bytes = Self.bytes(from: object["data"]),
                  let pending = Self.pending(from: object) else { return nil }
            return .snapshot(
                surfaceID: surfaceID,
                columns: size.columns,
                rows: size.rows,
                bytes: bytes,
                colors: CloudTuiRemoteColors(json: object["colors"]),
                pending: pending
            )
        case "output":
            guard let bytes = Self.bytes(from: object["data"]) else { return nil }
            return .output(surfaceID: surfaceID, bytes: bytes, colors: CloudTuiRemoteColors(json: object["colors"]))
        case "resized":
            guard let size = Self.size(from: object),
                  let bytes = Self.bytes(
                      from: (object["replay"] as? String) ?? (object["data"] as? String)
                  ),
                  let pending = Self.pending(from: object) else { return nil }
            return .resized(
                surfaceID: surfaceID,
                columns: size.columns,
                rows: size.rows,
                bytes: bytes,
                colors: CloudTuiRemoteColors(json: object["colors"]),
                pending: pending
            )
        case "colors-changed":
            // The daemon flattens the colors object into the event itself.
            guard let colors = CloudTuiRemoteColors(json: object) else { return nil }
            return .colorsChanged(surfaceID: surfaceID, colors: colors)
        case "detached":
            let actor = Self.decode(TerminalDetachActor.self, from: object["by"])
            return .detached(
                surfaceID: surfaceID,
                reason: TerminalDetachReason(wireValue: object["reason"] as? String, by: actor),
                view: object["view"] as? String
            )
        case "size-state":
            guard let state = Self.decode(TerminalSizingState.self, from: object["state"]) else { return nil }
            return .sizeState(surfaceID: surfaceID, state: state)
        case "overflow":
            return .overflow(surfaceID: surfaceID)
        default:
            return nil
        }
    }

    private static func sizingResponse(from data: [String: Any]?) -> CloudTuiSizingResponse? {
        guard let data else { return nil }
        let participant = data["participant"] as? String
        let state = decode(TerminalSizingState.self, from: data["state"])
        guard participant != nil || state != nil else { return nil }
        return CloudTuiSizingResponse(participant: participant, state: state)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from value: Any?) -> T? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
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

    /// The optional `pending` field. Older daemons and replays taken at a
    /// parser boundary omit it; a present but malformed value rejects the
    /// frame like any other malformed payload.
    private static func pending(from object: [String: Any]) -> Data? {
        guard let value = object["pending"] else { return Data() }
        return bytes(from: value)
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
