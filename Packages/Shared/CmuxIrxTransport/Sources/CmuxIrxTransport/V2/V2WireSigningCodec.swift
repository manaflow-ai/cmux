public import Foundation
import CoreFoundation

/// Produces the canonical bytes shared with the v2 Worker's signature verifier.
public struct V2WireSigningCodec: Sendable {
    /// Creates a stateless wire encoder.
    public init() {}

    /// Encodes JSON with sorted UTF-16 keys, unescaped slashes, and integer numbers.
    /// - Parameter value: A generated v2 wire value.
    /// - Returns: Canonical UTF-8 data accepted by the Worker.
    /// - Throws: An encoding error for a non-JSON or unsafe-number value.
    public func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoded = try JSONEncoder().encode(value)
        let object = try JSONSerialization.jsonObject(with: encoded, options: [.fragmentsAllowed])
        return Data(try canonical(object).utf8)
    }

    /// Encodes an enrollment proof without introducing a second wire schema.
    /// - Parameters:
    ///   - device: The complete descriptor included in the challenge request.
    ///   - challenge: The server's current single-use challenge.
    /// - Returns: Bytes signed by this device's IROH private key.
    /// - Throws: An encoding error if a wire value cannot be represented.
    public func enrollment(device: V2DeviceDescriptor, challenge: V2Challenge) throws -> Data {
        struct Enrollment: Encodable {
            let purpose = "cmux-iroh-v2-enrollment"
            let device: V2DeviceDescriptor
            let challengeId: String
            let nonce: String
        }
        return try encode(Enrollment(device: device, challengeId: challenge.challengeID, nonce: challenge.nonce))
    }

    /// Encodes the request proof around its exact unsigned body.
    /// - Parameters:
    ///   - device: The signing device's scoped descriptor.
    ///   - requestID: The identifier of this single request.
    ///   - issuedAt: Current Unix time in whole seconds.
    ///   - body: The setup or HTTP operation excluding the proof field itself.
    /// - Returns: Bytes bound to this operation, scope, and device key.
    /// - Throws: An encoding error if the body is not canonical JSON.
    public func request<Body: Encodable>(device: V2DeviceDescriptor, requestID: String, issuedAt: Int, body: Body) throws -> Data {
        try encode(RequestProofBody(
            identity: device.identity, endpointId: device.endpointID,
            identityGeneration: device.identityGeneration, requestId: requestID,
            issuedAt: issuedAt, body: body
        ))
    }

    /// Converts bytes to the unpadded URL-safe form used in v2 headers and signatures.
    /// - Parameter data: Raw bytes to encode.
    /// - Returns: A base64url string without padding.
    public func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private struct RequestProofBody<Body: Encodable>: Encodable {
        let purpose = "cmux-iroh-v2-request"
        let identity: V2Identity
        let endpointId: String
        let identityGeneration: Int
        let requestId: String
        let issuedAt: Int
        let body: Body
    }

    private func quoted(_ value: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes])
        return String(decoding: data.dropFirst().dropLast(), as: UTF8.self)
    }

    private func canonical(_ value: Any) throws -> String {
        if value is NSNull { return "null" }
        if let value = value as? String { return try quoted(value) }
        if let value = value as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() { return value.boolValue ? "true" : "false" }
            let number = value.doubleValue
            guard number.isFinite, number.rounded() == number, abs(number) <= 9_007_199_254_740_991 else {
                throw V2ControlFailure.invalidWireData
            }
            return String(Int64(number))
        }
        if let array = value as? [Any] { return "[" + (try array.map(canonical)).joined(separator: ",") + "]" }
        if let object = value as? [String: Any] {
            let keys = object.keys.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
            return "{" + (try keys.map { try quoted($0) + ":" + canonical(object[$0]!) }).joined(separator: ",") + "}"
        }
        throw V2ControlFailure.invalidWireData
    }
}
