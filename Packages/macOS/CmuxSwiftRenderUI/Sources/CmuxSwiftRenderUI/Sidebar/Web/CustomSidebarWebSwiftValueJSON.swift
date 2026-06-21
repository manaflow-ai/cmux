import CmuxSwiftRender
import Foundation

/// Converts interpreter values into plain JSON for HTML custom sidebars.
struct CustomSidebarWebSwiftValueJSON {
    let value: SwiftValue

    var jsonObject: Any {
        switch value {
        case let .int(number):
            return number
        case let .double(number):
            return number.isFinite ? number : NSNull()
        case let .string(string):
            return string
        case let .bool(bool):
            return bool
        case let .range(lower, upper, inclusive):
            return [
                "lower": lower,
                "upper": upper,
                "inclusive": inclusive,
                "display": value.displayString,
            ] as [String: Any]
        case let .array(values):
            return values.map { CustomSidebarWebSwiftValueJSON(value: $0).jsonObject }
        case let .object(fields):
            return fields.reduce(into: [String: Any]()) { result, entry in
                result[entry.key] = CustomSidebarWebSwiftValueJSON(value: entry.value).jsonObject
            }
        }
    }
}
