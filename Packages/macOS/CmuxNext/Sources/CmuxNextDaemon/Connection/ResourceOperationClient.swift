public import CmuxNextIPC
import Foundation

/// One `cmux.protocol/2` request line ``DaemonConnection`` sends: a generated
/// `ResourceRequestLine`, or the relay's runtime-named `ResourceRequestEnvelope`
/// (``ResourceRelayClient``).
protocol DaemonResourceLine {
    /// The operation's wire name (`closed.reopen`): the transport's trace and wait label.
    var operation: String { get }
    /// The line's bytes, without the trailing newline the transport adds.
    func lineData() throws -> Data
}

extension ResourceRequestEnvelope: DaemonResourceLine {
    func lineData() throws -> Data { try line() }
}

extension ResourceRequestLine: DaemonResourceLine {
    var operation: String { Request.resourceOperation }
    func lineData() throws -> Data { try line() }
}

/// Sends the generated `cmux.protocol/2` requests (CmuxNextIPC's `V2<Operation>Request`) on a
/// connection. The request type names the operation, spells its params and says whether it takes
/// an idempotency key, so a call site writes no operation name and no params dictionary (p05-ipc
/// Q11). Mojo's generated proxies work the same way: the caller fills a typed params struct and
/// the bindings serialize it (mojo/public/tools/bindings/generators/cpp_templates/
/// interface_definition.tmpl). Its own type, not a `DaemonConnection` member (that type's line
/// budget is frozen).
public struct ResourceOperationClient: Sendable {
    public let connection: DaemonConnection

    public init(connection: DaemonConnection) {
        self.connection = connection
    }

    /// Sends read (or connection control) `request` and decodes its `result` as `type`.
    /// Refusals arrive as `DaemonError.command` with the daemon's code.
    public func read<Request: ResourceUnkeyedRequest, Value: Decodable & Sendable>(
        _ request: Request, as type: Value.Type, timeout: Duration? = nil
    ) async throws -> Value {
        try await connection.resourceRequest({ id in
            ResourceRequestLine(id: id, request: request)
        }, as: type, timeout: timeout)
    }

    /// Sends mutation `request` under `idempotencyKey` and decodes its `result` as `type`. A key
    /// the daemon would refuse throws `ResourceWireError.invalidIdempotencyKey` before anything
    /// is sent.
    public func mutate<Request: ResourceMutationRequest, Value: Decodable & Sendable>(
        _ request: Request, idempotencyKey: String, as type: Value.Type, timeout: Duration? = nil
    ) async throws -> Value {
        let key = try ResourceIdempotencyKey(idempotencyKey)
        return try await connection.resourceRequest({ id in
            ResourceRequestLine(id: id, request: request, idempotencyKey: key)
        }, as: type, timeout: timeout)
    }
}

extension FieldUpdate {
    /// The generated request's spelling of this update, each value mapped by `transform`.
    func resourceField<Wire: Sendable>(_ transform: (Value) -> Wire) -> ResourceFieldUpdate<Wire> {
        switch self {
        case .unchanged: .unchanged
        case .clear: .clear
        case .set(let value): .set(transform(value))
        }
    }
}

extension ResourceJSON {
    /// The same JSON value in CmuxNextIPC's spelling (a generated `json` field takes it).
    init(_ value: JSONValue) {
        switch value {
        case .null: self = .null
        case .bool(let bool): self = .bool(bool)
        case .number(let number): self = .number(number)
        case .string(let string): self = .string(string)
        case .array(let items): self = .array(items.map { ResourceJSON($0) })
        case .object(let members): self = .object(members.mapValues { ResourceJSON($0) })
        }
    }
}
