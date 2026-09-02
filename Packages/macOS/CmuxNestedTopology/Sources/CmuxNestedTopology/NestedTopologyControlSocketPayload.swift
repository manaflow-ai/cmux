public import Foundation

/// Encodes nested topology read/focus results into Foundation JSON objects
/// suitable for cmux control-socket replies (`JSONSerialization` / `JSONValue`).
///
/// Uses snake_case Codable keys from the public read types. Callers bridge via
/// `JSONValue(foundationObject:)` on the app/control-socket side.
///
/// Construct at the control-socket composition seam rather than ambient statics.
public struct NestedTopologyControlSocketPayload: Sendable {
    /// Creates a payload encoder/decoder.
    public init() {}

    /// Encodes a list result as a Foundation dictionary.
    public func foundationObject(for result: NestedTopologyReadListResult) -> [String: Any]? {
        encodeToDictionary(result)
    }

    /// Encodes a focus result as a Foundation dictionary.
    public func foundationObject(for result: NestedNodeFocusResult) -> [String: Any]? {
        encodeToDictionary(result)
    }

    /// Encodes attachments for an additive `system.tree` `nested` field.
    public func foundationNestedTreeObject(
        attachments: [NestedTopologyReadAttachment]
    ) -> [String: Any]? {
        let envelope = NestedTopologyReadListResult(attachments: attachments)
        return encodeToDictionary(envelope)
    }

    /// Whether `include_nested` was requested in control-socket params.
    public func includeNestedRequested(_ params: [String: Any]) -> Bool {
        if let bool = params["include_nested"] as? Bool {
            return bool
        }
        if let number = params["include_nested"] as? NSNumber {
            return number.boolValue
        }
        return false
    }

    /// Decodes a structured compound ``NestedNodeID`` from a Foundation JSON object.
    public func decodeNodeID(from foundation: Any?) -> NestedNodeID? {
        guard let foundation else { return nil }
        guard JSONSerialization.isValidJSONObject(foundation) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: foundation) else { return nil }
        return try? JSONDecoder().decode(NestedNodeID.self, from: data)
    }

    private func encodeToDictionary<T: Encodable>(_ value: T) -> [String: Any]? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        guard let data = try? encoder.encode(value) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return object as? [String: Any]
    }
}
