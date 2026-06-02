import Foundation

extension CMUXBrowserMCPServer {
    func stringArgument(_ arguments: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = arguments[key] as? String {
                return value
            }
            if let value = arguments[key] as? NSNumber {
                return value.stringValue
            }
        }
        return nil
    }

    func boolArgument(_ arguments: [String: Any], key: String) -> Bool? {
        cli.boolFromAny(arguments[key])
    }

    func intArgument(_ arguments: [String: Any], key: String) -> Int? {
        cli.intFromAny(arguments[key])
    }

    func copyString(_ arguments: [String: Any], from sourceKey: String, to destinationKey: String, into params: inout [String: Any]) {
        if let value = stringArgument(arguments, keys: [sourceKey]) {
            params[destinationKey] = value
        }
    }

    func hasText(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
