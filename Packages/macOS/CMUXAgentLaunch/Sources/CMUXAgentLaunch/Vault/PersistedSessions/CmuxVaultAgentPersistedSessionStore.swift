import Foundation

/// A persisted agent-session store that cmux knows how to resolve safely.
public enum CmuxVaultAgentPersistedSessionStore: String, Codable, Hashable, Sendable {
    /// Hermes's SQLite `state.db` session store.
    case hermesStateDB

    /// Creates a store identifier from a Vault configuration value.
    ///
    /// - Parameter configurationValue: A supported persisted-store spelling.
    public init?(configurationValue: String) {
        switch configurationValue.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "hermesStateDB", "hermes-state-db", "stateDB", "state-db":
            self = .hermesStateDB
        default:
            return nil
        }
    }

    /// Returns an explicitly requested session ID from an agent launch command.
    ///
    /// Fresh sessions are correlated by agent hooks; the store is never searched by cwd because
    /// that cannot prove which live process owns a row.
    /// Hermes accepts separated, equals-separated, and attached short resume values such as
    /// `-r SESSION`, `-r=SESSION`, and `-rSESSION`.
    ///
    /// - Parameter arguments: The observed agent process arguments.
    /// - Returns: The explicit session ID, or `nil` when the launch is a fresh session.
    public func explicitSessionID(arguments: [String]) -> String? {
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
            let equalsPrefix = option + "="
            if argument.hasPrefix(equalsPrefix) {
                let value = String(argument.dropFirst(equalsPrefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty, !value.hasPrefix("-") {
                    return value
                }
                continue
            }
            if option.count == 2, argument.hasPrefix(option) {
                let value = String(argument.dropFirst(option.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty, !value.hasPrefix("-") {
                    return value
                }
            }
        }
        return nil
    }
}
