/// The JSON-RPC request envelope `{"id", "method", "params"}` encoded by
/// ``MobileCoreRPCClient/requestData(method:params:id:)``.
struct MobileRPCRequestEnvelope<Params: Encodable>: Encodable {
    /// The request id the session router keys responses by.
    let id: String
    /// The RPC method name.
    let method: String
    /// The typed request parameters (always present on the wire, `{}` when empty).
    let params: Params
}
