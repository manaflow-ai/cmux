public import Foundation

/// One typed JSON-RPC request: a wire method bound one-to-one to its payload.
///
/// Each conforming type IS a complete request. It declares the single method
/// name its payload shape is defined for, its stored properties encode as the
/// `params` object, and ``requestData(id:)`` assembles the full envelope. This
/// makes a mismatched method/params combination unrepresentable; there is no
/// API that takes a free-form method string next to a payload.
///
/// ```swift
/// let frame = try MobileTerminalInputRequest(
///     workspaceID: workspaceID,
///     surfaceID: surfaceID,
///     text: "ls\n",
///     clientID: clientID
/// ).requestData()
/// ```
public protocol MobileRPCRequest: Encodable, Sendable {
    /// The JSON-RPC method name this request is bound to.
    static var method: String { get }
}

extension MobileRPCRequest {
    /// Encode this request as its JSON-RPC frame (`{"id", "method", "params"}`).
    ///
    /// The wire shape matches the legacy `[String: Any]` envelopes: `params` is
    /// always present (`{}` when the payload has no fields) and optional fields
    /// are omitted rather than encoded as JSON null.
    /// - Parameter id: The request id (defaults to a fresh UUID).
    /// - Returns: The encoded request data.
    /// - Throws: An encoding error when a payload value is not JSON-encodable.
    public func requestData(id: String = UUID().uuidString) throws -> Data {
        try JSONEncoder().encode(
            MobileRPCRequestEnvelope(id: id, method: Self.method, params: self)
        )
    }
}
