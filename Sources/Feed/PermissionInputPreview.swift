import Foundation

struct PermissionInputPreview {
    let sigil: String?
    let primary: String?
    let secondary: String?

    init(toolName: String, toolInputJSON: String) {
        let dict = (try? JSONSerialization.jsonObject(
            with: Data(toolInputJSON.utf8)
        )) as? [String: Any] ?? [:]

        switch toolName.lowercased() {
        case "bash":
            self.sigil = "$"
            self.primary = (dict["command"] as? String) ?? toolInputJSON
            self.secondary = (dict["description"] as? String)
        case "write", "edit", "multiedit":
            self.sigil = nil
            self.primary = (dict["file_path"] as? String) ?? toolInputJSON
            if toolName.lowercased() == "write" {
                let content = (dict["content"] as? String) ?? ""
                let preview = content.split(separator: "\n").first.map(String.init) ?? ""
                self.secondary = preview.isEmpty ? nil : preview
            } else {
                self.secondary = nil
            }
        case "read":
            self.sigil = nil
            self.primary = (dict["file_path"] as? String) ?? toolInputJSON
            self.secondary = nil
        default:
            self.sigil = nil
            self.primary = toolInputJSON == "{}" ? nil : toolInputJSON
            self.secondary = nil
        }
    }
}

/// Single DRY button primitive used across every actionable card
/// (permission / plan / question / filter pills / option pills).
/// Replaces the old PermissionCTAButton / PlanCTAButton /
/// FeedPillButton trio so styling is defined in exactly one place.
