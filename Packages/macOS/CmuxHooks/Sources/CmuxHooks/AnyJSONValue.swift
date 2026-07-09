import Foundation

struct AnyJSONValue: Sendable, Equatable {
    private let storage: Storage

    init(_ value: Any) {
        self.storage = Storage(value)
    }

    var argumentText: String {
        switch storage {
        case .null:
            return ""
        case .string(let value):
            return value
        case .number(let value):
            return value
        case .bool(let value):
            return value ? "true" : "false"
        case .array, .object:
            guard let object = storage.jsonObject,
                  JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                  let text = String(data: data, encoding: .utf8) else {
                return ""
            }
            return text
        }
    }

    func child(named name: String) -> AnyJSONValue? {
        guard case .object(let object) = storage else { return nil }
        return object[name]
    }

    private indirect enum Storage: Sendable, Equatable {
        case null
        case string(String)
        case number(String)
        case bool(Bool)
        case array([AnyJSONValue])
        case object([String: AnyJSONValue])

        init(_ value: Any) {
            switch value {
            case _ as NSNull:
                self = .null
            case let value as String:
                self = .string(value)
            case let value as NSNumber:
                if CFGetTypeID(value) == CFBooleanGetTypeID() {
                    self = .bool(value.boolValue)
                } else {
                    self = .number(value.stringValue)
                }
            case let value as Bool:
                self = .bool(value)
            case let value as [Any]:
                self = .array(value.map(AnyJSONValue.init))
            case let value as [String: Any]:
                self = .object(value.mapValues(AnyJSONValue.init))
            default:
                self = .string(String(describing: value))
            }
        }

        var jsonObject: Any? {
            switch self {
            case .null:
                return NSNull()
            case .string(let value):
                return value
            case .number(let value):
                return Decimal(string: value).map(NSDecimalNumber.init(decimal:))
            case .bool(let value):
                return value
            case .array(let values):
                return values.compactMap { $0.storage.jsonObject }
            case .object(let object):
                return object.mapValues { $0.storage.jsonObject ?? NSNull() }
            }
        }
    }
}
