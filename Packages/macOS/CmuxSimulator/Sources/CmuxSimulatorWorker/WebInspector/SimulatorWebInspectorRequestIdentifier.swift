import Foundation

enum SimulatorWebInspectorRequestIdentifier: Hashable {
    case number(String)
    case string(String)

    var foundationValue: Any {
        switch self {
        case let .number(value): NSNumber(value: Double(value) ?? 0)
        case let .string(value): value
        }
    }
}
