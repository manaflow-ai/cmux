import Foundation

struct CmxHiveAttachPayload: Encodable, Equatable {
    let endpoint: CmxHivePublishJSONValue
    let pairingID: String
    let rivetEndpoint: String?
    let stackProjectID: String
    let expiresAtUnix: UInt64

    private enum CodingKeys: String, CodingKey {
        case endpoint
        case pairingID = "pairing_id"
        case rivetEndpoint = "rivet_endpoint"
        case stackProjectID = "stack_project_id"
        case expiresAtUnix = "expires_at_unix"
    }

    static func fromTicket(_ ticket: String) -> CmxHiveAttachPayload? {
        guard let data = ticket.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let endpointObject = object["endpoint"],
              let endpoint = CmxHivePublishJSONValue(endpointObject),
              let auth = object["auth"] as? [String: Any],
              let pairingID = normalizedNonEmpty(auth["pairing_id"]),
              let stackProjectID = normalizedNonEmpty(auth["stack_project_id"]),
              let expiresAtUnix = uint64Value(auth["expires_at_unix"]),
              expiresAtUnix > 0 else {
            return nil
        }

        return CmxHiveAttachPayload(
            endpoint: endpoint,
            pairingID: pairingID,
            rivetEndpoint: normalizedNonEmpty(auth["rivet_endpoint"]),
            stackProjectID: stackProjectID,
            expiresAtUnix: expiresAtUnix
        )
    }

    private static func normalizedNonEmpty(_ value: Any?) -> String? {
        guard let trimmed = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func uint64Value(_ value: Any?) -> UInt64? {
        if let value = value as? UInt64, value > 0 {
            return value
        }
        if let value = value as? NSNumber, value.doubleValue > 0 {
            return value.uint64Value
        }
        if let value = value as? Int, value > 0 {
            return UInt64(value)
        }
        if let value = value as? Double, value > 0 {
            return UInt64(value)
        }
        if let value = value as? String, let parsed = UInt64(value), parsed > 0 {
            return parsed
        }
        return nil
    }
}

enum CmxHivePublishJSONValue: Encodable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: CmxHivePublishJSONValue])
    case array([CmxHivePublishJSONValue])
    case null

    init?(_ value: Any) {
        switch value {
        case let value as String:
            self = .string(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .bool(value.boolValue)
            } else {
                self = .number(value.doubleValue)
            }
        case let value as [String: Any]:
            var object: [String: CmxHivePublishJSONValue] = [:]
            for (key, value) in value {
                guard let encoded = CmxHivePublishJSONValue(value) else { return nil }
                object[key] = encoded
            }
            self = .object(object)
        case let value as [Any]:
            var array: [CmxHivePublishJSONValue] = []
            for item in value {
                guard let encoded = CmxHivePublishJSONValue(item) else { return nil }
                array.append(encoded)
            }
            self = .array(array)
        case _ as NSNull:
            self = .null
        default:
            return nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}
