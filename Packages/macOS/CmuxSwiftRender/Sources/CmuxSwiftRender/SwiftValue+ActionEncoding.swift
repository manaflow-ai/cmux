import Foundation

extension SwiftValue {
    /// Encodes a value for a sidebar action's string-only parameter channel.
    ///
    /// Scalar values retain their display spelling. Arrays and objects use
    /// valid JSON so the host dispatcher can restore their types (for example,
    /// `layout` and `workspace_env`) instead of silently dropping them.
    var actionParameterString: String {
        switch self {
        case .array, .object:
            return actionJSONData
                .flatMap { String(data: $0, encoding: .utf8) }
                ?? "null"
        default:
            return displayString
        }
    }

    private var actionJSONData: Data? {
        guard JSONSerialization.isValidJSONObject(actionJSONObject) else { return nil }
        return try? JSONSerialization.data(
            withJSONObject: actionJSONObject,
            options: [.sortedKeys]
        )
    }

    private var actionJSONObject: Any {
        switch self {
        case let .int(value):
            return value
        case let .double(value):
            // JSON has no non-finite numeric literals. Preserve a valid action
            // payload so the host can reject the resulting null at its typed
            // parameter boundary instead of receiving malformed JSON.
            return value.isFinite ? value : NSNull()
        case let .string(value):
            return value
        case let .bool(value):
            return value
        case let .range(lower, upper, inclusive):
            return "\(lower)\(inclusive ? "..." : "..<")\(upper)"
        case let .array(values):
            return values.map(\.actionJSONObject)
        case let .object(fields):
            return fields.mapValues(\.actionJSONObject)
        }
    }
}
