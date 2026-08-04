import Foundation

/// A typed persisted-session store capability.
///
/// Config decoding may name a store, but resolution remains fail-closed unless the registration
/// exactly matches the cmux-owned built-in that owns it.
enum CmuxVaultAgentPersistedSessionStore: String, Codable, Hashable, Sendable {
    case hermesStateDB

    init?(configurationValue: String) {
        switch configurationValue.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "hermesStateDB", "hermes-state-db", "stateDB", "state-db":
            self = .hermesStateDB
        default:
            return nil
        }
    }

    func explicitSessionID(arguments: [String]) -> String? {
        switch self {
        case .hermesStateDB:
            return Self.optionValue("--resume", arguments: arguments)
                ?? Self.optionValue("-r", arguments: arguments)
        }
    }

    private static func optionValue(_ option: String, arguments: [String]) -> String? {
        for index in arguments.indices {
            let argument = arguments[index]
            if argument == option {
                let valueIndex = arguments.index(after: index)
                guard valueIndex < arguments.endIndex else { continue }
                let value = arguments[valueIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty, !value.hasPrefix("-") {
                    return value
                }
                continue
            }
            let prefix = option + "="
            guard argument.hasPrefix(prefix) else { continue }
            let value = String(argument.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty, !value.hasPrefix("-") {
                return value
            }
        }
        return nil
    }
}
