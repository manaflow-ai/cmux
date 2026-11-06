public import CmuxNextDaemon
public import Foundation

/// The Cloud machine record's rules and the small Cloud API models' readers, asked of Rust
/// (cmux-tui/crates/cmux-cloud-machine, with their tests) over the app FFI's JSON channel (ops
/// `cloud_machine_*` and `cloud_model_*`, through ``CloudStartCore/callData(_:_:startingCapacity:)``).
/// The app's records are that crate's JSON: camelCase fields, timestamps in epoch milliseconds.
public nonisolated struct CloudMachineRules: Sendable {
    public init() {}

    /// One call: `request` encoded, the reply decoded as `Reply`; nil when the FFI does not answer.
    public func call<Request: Encodable, Reply: Decodable>(_ operation: String, _ request: Request, as: Reply.Type) -> Reply? {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let data = try? encoder.encode(request),
              let reply = CloudStartCore().callData(operation, data, startingCapacity: 4096) else { return nil }
        return try? decoder.decode(Reply.self, from: reply)
    }

    /// A server answer of `kind` (cmux-cloud-machine `models::KINDS`) read into `T`; throws
    /// ``CloudAPIError/decoding(_:)`` naming `context` when the answer is not one.
    public func read<T: Decodable>(_ kind: String, _ answer: Data, as: T.Type, context: String) throws -> T {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: answer) else {
            throw CloudAPIError.decoding("\(context): not JSON")
        }
        return try read(kind, value, as: T.self, context: context)
    }

    /// ``read(_:_:as:context:)`` of an answer already parsed.
    public func read<T: Decodable>(_ kind: String, _ value: JSONValue, as: T.Type, context: String) throws -> T {
        struct Request: Encodable { var kind: String, value: JSONValue }
        struct Reply: Decodable { var value: T?, error: String? }
        guard let reply = call("cloud_model_read", Request(kind: kind, value: value), as: Reply.self) else {
            throw CloudAPIError.decoding("\(context): the app FFI did not answer")
        }
        guard let read = reply.value else { throw CloudAPIError.decoding("\(context): \(reply.error ?? "unreadable")") }
        return read
    }

    // MARK: The record

    /// What the app reads off one record.
    public struct Facts: Sendable, Equatable, Decodable {
        public var capabilities = CloudMachine.Capabilities()
        public var allowed: [CloudMachine.Capabilities.Operation] = []
        public var hasRun = false
        public var goneForPhones = false
        public var agentInfrastructure = false
        public var desktopViewer = "web"

        init() {}
    }

    /// `machine`'s facts for the signed-in `user`; an FFI that does not answer allows nothing.
    public func facts(_ machine: CloudMachine, user: String? = nil) -> Facts {
        struct Request: Encodable { var machine: CloudMachine, user: String? }
        return call("cloud_machine_facts", Request(machine: machine, user: user), as: Facts.self) ?? Facts()
    }

    struct Statuses: Decodable {
        var live: Set<CloudMachine.Status> = []
        var changing: Set<CloudMachine.Status> = []
    }

    /// Which statuses are live and which are a change on its way (read once).
    static let statuses: Statuses = CloudMachineRules().call("cloud_machine_statuses", [String: String](), as: Statuses.self) ?? Statuses()
}
