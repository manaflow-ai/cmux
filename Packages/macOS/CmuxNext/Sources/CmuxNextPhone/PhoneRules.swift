internal import CCmuxLayoutReducerFFI
import Foundation

/// The phone tab's rules in Rust (`cmux-phone-core`, the app FFI's `phone` op): the tools' output
/// parsing, keyboard usages, paced touches, the screen mapping and the adb calls of an input.
/// Swift runs the tools and passes their output.
enum PhoneRules {
    /// One `phone` request (`op` plus `fields`); the reply's object. Nil when Rust does not answer.
    static func ask(_ op: String, _ fields: [String: Any] = [:]) -> [String: Any]? {
        guard let reply = raw(op, fields) else { return nil }
        return (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any]
    }

    /// One `phone` request, the reply's `key` decoded as `T` (a reply with that one key).
    static func decode<T: Decodable>(_ type: T.Type, _ key: String, _ op: String, _ fields: [String: Any], what: String) throws -> T {
        try reply([String: T].self, op, fields, what: what)[key].unwrap(what)
    }

    /// One `phone` request, the whole reply decoded as `T`. An `{"error":"unreadable"}` reply throws
    /// ``PhoneError/unreadable(what:)``, as does no reply (naming `what`); another error kind throws ``Refusal``.
    static func reply<T: Decodable>(_ type: T.Type, _ op: String, _ fields: [String: Any], what: String) throws -> T {
        guard let reply = raw(op, fields) else { throw PhoneError.unreadable(what: what) }
        if let object = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any], let kind = object["error"] as? String {
            if kind == "unreadable" { throw PhoneError.unreadable(what: object["what"] as? String ?? what) }
            throw Refusal(kind: kind)
        }
        do {
            return try JSONDecoder().decode(T.self, from: reply)
        } catch {
            throw PhoneError.unreadable(what: what)
        }
    }

    /// A rule's `{"error": KIND}` answer other than unreadable (`outside_screen`, `unsupported`).
    struct Refusal: Error, Equatable {
        let kind: String
    }

    /// The tool's output as the JSON string Rust reads.
    static func text(_ output: Data) -> String { String(decoding: output, as: UTF8.self) }

    /// `value` as a request field (its JSON object); null when it does not encode.
    static func field<T: Encodable>(_ value: T) -> Any {
        (try? JSONEncoder().encode(value)).flatMap { try? JSONSerialization.jsonObject(with: $0, options: .fragmentsAllowed) } ?? NSNull()
    }

    private static func raw(_ op: String, _ fields: [String: Any]) -> Data? {
        var body = fields
        body["op"] = op
        // A NaN or infinite number raises in JSONSerialization; such a request has no answer.
        guard JSONSerialization.isValidJSONObject(body), let request = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        return call(request)
    }

    private static func call(_ request: Data) -> Data? {
        var capacity = 4096
        for _ in 0..<2 {
            var output = [UInt8](repeating: 0, count: capacity)
            var length = 0
            let code: Int32 = request.withUnsafeBytes { bytes in
                "phone".withCString { op in
                    output.withUnsafeMutableBytes { out in
                        cmux_layout_reducer_json(bytes.bindMemory(to: UInt8.self).baseAddress, request.count, op,
                                                 out.bindMemory(to: UInt8.self).baseAddress, out.count, &length)
                    }
                }
            }
            if code == CMUX_LAYOUT_REDUCER_ERR_BUFFER, length > capacity { capacity = length; continue }
            guard code == CMUX_LAYOUT_REDUCER_OK, length <= capacity else { return nil }
            return Data(output.prefix(length))
        }
        return nil
    }
}

private extension Optional {
    func unwrap(_ what: String) throws -> Wrapped {
        guard let self else { throw PhoneError.unreadable(what: what) }
        return self
    }
}

/// A device as `cmux-phone-core` reads and writes it (`os_version`, `state.kind`).
struct PhoneDeviceReply: Codable {
    let id: PhoneDeviceID
    let name: String
    let model: String
    let osVersion: String
    let state: State
    let transport: String?

    enum CodingKeys: String, CodingKey {
        case id, name, model, state, transport
        case osVersion = "os_version"
    }

    struct State: Codable {
        let kind: String
        let reason: String?
    }

    init(_ device: PhoneDevice) {
        id = device.id
        name = device.name
        model = device.model
        osVersion = device.osVersion
        transport = device.transport
        state = switch device.state {
        case .shutdown: State(kind: "shutdown", reason: nil)
        case .booting: State(kind: "booting", reason: nil)
        case .ready: State(kind: "ready", reason: nil)
        case .disconnected: State(kind: "disconnected", reason: nil)
        case .unavailable(let reason): State(kind: "unavailable", reason: reason)
        }
    }

    var device: PhoneDevice {
        let status: PhoneDeviceState = switch state.kind {
        case "booting": .booting
        case "ready": .ready
        case "disconnected": .disconnected
        case "unavailable": .unavailable(reason: state.reason ?? "unavailable")
        default: .shutdown
        }
        return PhoneDevice(id: id, name: name, model: model, osVersion: osVersion, state: status, transport: transport)
    }
}
