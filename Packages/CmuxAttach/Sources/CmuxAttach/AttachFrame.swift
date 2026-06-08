import Foundation

/// One message on the attach wire.
///
/// The transport is newline-delimited JSON over the existing control socket,
/// the same shape `events.stream` uses, so attach needs no new listener. Each
/// frame is a single JSON object with a `t` (type) discriminator plus the
/// fields that type carries. Raw PTY bytes ride as base64 inside the JSON
/// (`output`/`input`) - a deliberate v1 stopgap, byte-exact and newline-safe;
/// a later version can switch those two types to a binary opcode on the same
/// connection without touching control frames.
///
/// Both ends (the host's `SurfaceAttachSession` and the `cmux attach` CLI)
/// encode and decode through this one type so the wire cannot drift.
public enum AttachFrame: Sendable, Equatable {
    /// Client -> host: open an attach to a surface.
    case attach(AttachRequest)
    /// Host -> client: attach accepted; `seq` is the byte sequence the live
    /// stream will continue from, so the client can detect drops.
    case ack(seq: UInt64)
    /// Host -> client: a chunk of raw PTY output. `seq` is the byte offset of
    /// the first byte in this chunk.
    case output(seq: UInt64, bytes: Data)
    /// Client -> host: raw stdin bytes for the pane.
    case input(bytes: Data)
    /// Client -> host: the client's terminal was resized.
    case resize(cols: Int, rows: Int)
    /// Either direction: tear down this attachment, leaving the pane running.
    case detach
    /// Host -> client: the attach failed or was closed; `code` is machine
    /// readable, `message` is for a human.
    case error(code: String, message: String)
    /// Host -> client: keep-alive when the stream is idle.
    case heartbeat

    private enum TypeTag: String {
        case attach, ack, output = "out", input = "in", resize = "rz"
        case detach, error = "err", heartbeat = "hb"
    }

    /// Encode this frame to a single newline-terminated wire line.
    public func encodedLine() -> Data {
        var object: [String: Any] = ["t": tag.rawValue]
        switch self {
        case .attach(let request):
            object["surface"] = request.surface
            object["cols"] = request.size.cols
            object["rows"] = request.size.rows
            object["read_only"] = request.readOnly
            object["v"] = request.version
        case .ack(let seq):
            object["seq"] = seq
        case .output(let seq, let bytes):
            object["seq"] = seq
            object["b64"] = bytes.base64EncodedString()
        case .input(let bytes):
            object["b64"] = bytes.base64EncodedString()
        case .resize(let cols, let rows):
            object["cols"] = cols
            object["rows"] = rows
        case .detach, .heartbeat:
            break
        case .error(let code, let message):
            object["code"] = code
            object["message"] = message
        }
        // sortedKeys keeps output deterministic so tests can assert on bytes.
        let json = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        var line = json
        line.append(0x0A) // "\n"
        return line
    }

    /// Decode one wire line (with or without the trailing newline) into a frame.
    public init(line: Data) throws {
        var bytes = line
        if bytes.last == 0x0A { bytes.removeLast() }
        guard !bytes.isEmpty else { throw AttachFrameError.malformed }
        guard let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw AttachFrameError.malformed
        }
        guard let rawType = object["t"] as? String else {
            throw AttachFrameError.missingField("t")
        }
        guard let type = TypeTag(rawValue: rawType) else {
            throw AttachFrameError.unknownType(rawType)
        }

        switch type {
        case .attach:
            self = .attach(try AttachHandshake.parse(params: object))
        case .ack:
            self = .ack(seq: try AttachFrame.uint64(object["seq"]))
        case .output:
            self = .output(seq: try AttachFrame.uint64(object["seq"]), bytes: try AttachFrame.payload(object["b64"]))
        case .input:
            self = .input(bytes: try AttachFrame.payload(object["b64"]))
        case .resize:
            self = .resize(
                cols: try AttachFrame.intField(object["cols"], "cols"),
                rows: try AttachFrame.intField(object["rows"], "rows")
            )
        case .detach:
            self = .detach
        case .error:
            self = .error(
                code: (object["code"] as? String) ?? "error",
                message: (object["message"] as? String) ?? ""
            )
        case .heartbeat:
            self = .heartbeat
        }
    }

    private var tag: TypeTag {
        switch self {
        case .attach: return .attach
        case .ack: return .ack
        case .output: return .output
        case .input: return .input
        case .resize: return .resize
        case .detach: return .detach
        case .error: return .error
        case .heartbeat: return .heartbeat
        }
    }

    private static func uint64(_ raw: Any?) throws -> UInt64 {
        switch raw {
        case let value as UInt64: return value
        case let value as Int where value >= 0: return UInt64(value)
        case let value as Double where value >= 0 && value.rounded() == value: return UInt64(value)
        case let value as String:
            if let parsed = UInt64(value.trimmingCharacters(in: .whitespaces)) { return parsed }
            throw AttachFrameError.malformed
        default:
            throw AttachFrameError.missingField("seq")
        }
    }

    private static func intField(_ raw: Any?, _ name: String) throws -> Int {
        guard let value = AttachHandshake.intValue(raw) else {
            throw AttachFrameError.missingField(name)
        }
        return value
    }

    private static func payload(_ raw: Any?) throws -> Data {
        guard let encoded = raw as? String else { throw AttachFrameError.missingField("b64") }
        guard let data = Data(base64Encoded: encoded) else { throw AttachFrameError.invalidPayload }
        return data
    }
}

/// Why a wire line could not be decoded into a frame.
public enum AttachFrameError: Error, Equatable, Sendable {
    case malformed
    case missingField(String)
    case unknownType(String)
    case invalidPayload
}
