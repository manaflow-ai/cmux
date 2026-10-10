import Foundation

extension CmuxConfigSnapshot {
    /// Validates device-local chat settings and reports diagnostics at their schema keys.
    static func chatDiagnostics(_ root: JSONValue) -> [SettingsDiagnostic] {
        guard let value = root.value(at: ["agents", "chats"]) else { return [] }
        guard case .object(let members) = value else {
            return [SettingsDiagnostic(kind: .invalidValue, path: "agents.chats", message: "expected an object")]
        }
        var diagnostics: [SettingsDiagnostic] = []
        for key in ["enabled", "discovery"] {
            guard let value = members[key] else { continue }
            guard value.boolValue != nil else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "agents.chats.\(key)", message: "expected true or false"))
                continue
            }
        }
        guard let roots = members["roots"] else { return diagnostics }
        guard case .array(let items) = roots else {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "agents.chats.roots", message: "expected an array of absolute folder paths"))
            return diagnostics
        }
        let validator = ChatRootValidator()
        for item in items {
            guard let path = item.stringValue else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "agents.chats.roots", message: "expected an array of absolute folder paths"))
                continue
            }
            if let reason = validator.refusal(path) {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "agents.chats.roots", message: reason))
            }
        }
        return diagnostics
    }
}
