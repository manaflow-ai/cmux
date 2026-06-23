import Foundation

/// A human-readable preview of an agent permission request, parsed from the
/// tool name plus its raw `tool_input` JSON string.
///
/// The initializer decodes `toolInputJSON` with `JSONSerialization` and, based
/// on the (lowercased) tool name, pulls out a display `sigil`, a `primary` line
/// (the command, file path, or raw JSON), and an optional `secondary` line
/// (a description or a one-line content preview). It handles Bash
/// (`command` + `description`), Write / Edit / MultiEdit / Read (`file_path`,
/// plus a first-line content preview for Write), and falls back to the raw JSON
/// for everything else.
///
/// This is a pure Foundation value type with no app, SwiftUI, or I/O reach: the
/// only inputs are the two strings, and the only work is JSON parsing and string
/// selection. The presentation layer reads `sigil`/`primary`/`secondary` to lay
/// out the permission card.
public struct PermissionInputPreview {
    /// A short prefix glyph for the primary line (e.g. `"$"` for Bash), or
    /// `nil` when the tool has no meaningful sigil.
    public let sigil: String?

    /// The main line to display: the Bash command, the touched file path, or
    /// the raw JSON when no structured field applies. `nil` only when the input
    /// is an empty object (`"{}"`) for an unrecognized tool.
    public let primary: String?

    /// A supporting line under `primary`: a Bash `description`, the first line
    /// of Write `content`, or `nil` when there is nothing to add.
    public let secondary: String?

    /// Parses a permission request preview from a tool name and its raw
    /// `tool_input` JSON.
    ///
    /// - Parameters:
    ///   - toolName: The agent tool name (case-insensitive), e.g. `"Bash"`,
    ///     `"Write"`, `"Edit"`, `"MultiEdit"`, or `"Read"`.
    ///   - toolInputJSON: The raw `tool_input` JSON object string. Invalid JSON
    ///     is treated as an empty object, so `primary` falls back to the raw
    ///     string for recognized tools.
    public init(toolName: String, toolInputJSON: String) {
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
