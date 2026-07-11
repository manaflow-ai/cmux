import Foundation

enum AgentGUICodableBridge {
    static func dictionary<Value: Encodable>(_ value: Value) throws -> [String: Any] {
        let encoder = JSONEncoder()
        let data = try encoder.encode(value)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw AgentGUIRPCError.internalError
        }
        return dictionary
    }

    static func decode<Value: Decodable>(_ type: Value.Type, from params: [String: Any]) throws -> Value {
        let data = try JSONSerialization.data(withJSONObject: params)
        return try JSONDecoder().decode(type, from: data)
    }
}
