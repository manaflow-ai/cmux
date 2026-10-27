/// One `cmux.protocol/2` operation's params, generated per operation of
/// cmux-tui/spec/resource-operations-v2.json (CmuxNextWireGen's ResourceEmitter, p05-ipc task 024)
/// as `V2<Operation>Request`. The value encodes as the envelope's `params` object, selectors
/// included; `ResourceRequestLine` adds the envelope.
public protocol ResourceOperationRequest: Encodable, Sendable {
    /// The `result` of an `ok: true` response.
    associatedtype Result: Decodable & Sendable

    /// The wire name (`terminal.input.write`).
    static var resourceOperation: String { get }
}

/// An operation with `idempotency: required`: every request carries an idempotency key, so the
/// envelope builder takes one.
public protocol ResourceMutationRequest: ResourceOperationRequest {}

/// An operation with `idempotency: forbidden` (reads, connection control, stream opens): the
/// envelope builder takes no key.
public protocol ResourceUnkeyedRequest: ResourceOperationRequest {}
