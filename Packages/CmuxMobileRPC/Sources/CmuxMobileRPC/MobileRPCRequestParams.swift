public import Foundation

/// Typed JSON-RPC request parameters bound one-to-one to their wire method.
///
/// Each conforming type declares the single method name its payload shape is
/// defined for, and ``requestData(id:)`` assembles the full envelope from that
/// pair. This makes a mismatched method/params combination unrepresentable;
/// there is no API that takes a free-form method string next to a payload.
///
/// ```swift
/// let frame = try MobileTerminalInputParams(
///     workspaceID: workspaceID,
///     surfaceID: surfaceID,
///     text: "ls\n",
///     clientID: clientID
/// ).requestData()
/// ```
public protocol MobileRPCRequestParams: Encodable, Sendable {
    /// The JSON-RPC method name this parameter payload belongs to.
    static var method: String { get }
}

extension MobileRPCRequestParams {
    /// Encode this call as its JSON-RPC request frame (`{"id", "method", "params"}`).
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
