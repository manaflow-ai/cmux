import Foundation

/// Decodes the existing boolean aliases accepted by browser automation commands.
struct BrowserAutomationParameters {
    let values: [String: Any]

    func bool(keys: [String]) -> Bool {
        for key in keys {
            if let value = values[key] as? Bool {
                return value
            }
            if let value = values[key] as? String {
                switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "1", "true", "yes", "on":
                    return true
                default:
                    continue
                }
            }
        }
        return false
    }
}
