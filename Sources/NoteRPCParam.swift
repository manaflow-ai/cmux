import Foundation

/// Typed accessors for the loosely-typed `params` dictionaries of the
/// `note.*` socket RPCs (TerminalController+Notes.swift).
enum NoteRPCParam {
    static func rawString(_ params: [String: Any], _ key: String) -> String? {
        params[key] as? String
    }

    static func string(_ params: [String: Any], _ key: String) -> String? {
        guard let raw = params[key] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func bool(_ params: [String: Any], _ key: String) -> Bool? {
        if let value = params[key] as? Bool { return value }
        if let value = params[key] as? NSNumber { return value.boolValue }
        if let value = params[key] as? String {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on":
                return true
            case "0", "false", "no", "off":
                return false
            default:
                return nil
            }
        }
        return nil
    }
}
