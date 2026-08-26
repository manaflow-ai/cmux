import Foundation

/// Builds and removes cmux-owned Mistral Vibe hook blocks in TOML config files.
///
/// Vibe stores hooks in `~/.vibe/hooks.toml` as `[[hooks]]` array-of-tables with
/// `name`, `type`, `command`, and `timeout` fields. This mirrors the marker-delimited
/// text-transform approach used by ``KimiCodeHookConfig`` but emits the Vibe schema.
public enum VibeHookConfig {
    /// A Vibe hook event entry written as a TOML `[[hooks]]` table.
    public struct Event: Equatable, Sendable {
        /// The Vibe hook name (e.g. "cmux-stop").
        public var name: String
        /// The Vibe hook type: "post_agent", "pre_tool", or "post_tool".
        public var type: String
        /// The complete command string to execute for the event.
        public var command: String
        /// The hook timeout in seconds.
        public var timeout: Double

        /// Creates a Vibe hook event.
        /// - Parameters:
        ///   - name: The Vibe hook name.
        ///   - type: The Vibe hook type ("post_agent", "pre_tool", "post_tool").
        ///   - command: The complete command string to execute.
        ///   - timeout: The hook timeout in seconds.
        public init(name: String, type: String, command: String, timeout: Double) {
            self.name = name
            self.type = type
            self.command = command
            self.timeout = timeout
        }
    }

    private static let beginMarker =
        "# cmux-vibe-hooks-8a3f5c2d-1b4e-4f7a-9d6c-2e8b1a3f5c7d begin"
    private static let endMarker =
        "# cmux-vibe-hooks-8a3f5c2d-1b4e-4f7a-9d6c-2e8b1a3f5c7d end"

    /// Returns TOML content with exactly one cmux-owned Vibe hooks block.
    /// - Parameters:
    ///   - events: Hook events to write, in output order.
    ///   - existing: Existing TOML config content.
    /// - Returns: The updated TOML content.
    public static func installing(events: [Event], in existing: String) -> String {
        var lines = tomlLines(from: existing)
        removeCmuxVibeHooksBlock(from: &lines)

        var block: [String] = [beginMarker]
        for event in events {
            block.append(contentsOf: hookTableLines(event: event))
        }
        block.append(endMarker)

        if !lines.isEmpty, lines.last?.isEmpty == false {
            lines.append("")
        }
        lines.append(contentsOf: block)
        return tomlContent(from: lines)
    }

    /// Returns whether the content already carries a cmux-owned Vibe hooks block.
    /// - Parameter existing: Existing TOML config content.
    /// - Returns: `true` when a cmux marker block is present.
    public static func containsCmuxBlock(in existing: String) -> Bool {
        tomlLines(from: existing).contains { line in
            line.trimmingCharacters(in: .whitespaces) == beginMarker
        }
    }

    /// Returns TOML content after removing cmux-owned Vibe hooks blocks.
    /// - Parameter existing: Existing TOML config content.
    /// - Returns: The TOML content without cmux-owned Vibe hook blocks.
    public static func uninstalling(from existing: String) -> String {
        var lines = tomlLines(from: existing)
        removeCmuxVibeHooksBlock(from: &lines)
        return tomlContent(from: lines)
    }

    private static func hookTableLines(event: Event) -> [String] {
        return [
            "[[hooks]]",
            "name = \"\(tomlBasicStringContent(event.name))\"",
            "type = \"\(tomlBasicStringContent(event.type))\"",
            "command = \"\(tomlBasicStringContent(event.command))\"",
            "timeout = \(VibeHookConfig.formatTimeout(event.timeout))",
            "",
        ]
    }

    private static func formatTimeout(_ timeout: Double) -> String {
        if timeout == timeout.rounded() {
            return String(format: "%.1f", timeout)
        }
        return String(timeout)
    }

    private static func removeCmuxVibeHooksBlock(from lines: inout [String]) {
        var index = 0
        while index < lines.count {
            guard lines[index].trimmingCharacters(in: .whitespaces) == beginMarker else {
                index += 1
                continue
            }
            if let endIndex = lines[index...].firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces) == endMarker
            }) {
                lines.removeSubrange(index...endIndex)
            } else {
                lines.remove(at: index)
            }
        }
    }

    private static func tomlBasicStringContent(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count)

        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08:
                escaped += "\\b"
            case 0x09:
                escaped += "\\t"
            case 0x0A:
                escaped += "\\n"
            case 0x0C:
                escaped += "\\f"
            case 0x0D:
                escaped += "\\r"
            case 0x22:
                escaped += "\\\""
            case 0x5C:
                escaped += "\\\\"
            case 0x00...0x1F, 0x7F...0x9F:
                if scalar.value <= 0xFFFF {
                    escaped += String(format: "\\u%04X", scalar.value)
                } else {
                    escaped += String(format: "\\U%08X", scalar.value)
                }
            default:
                escaped.unicodeScalars.append(scalar)
            }
        }

        return escaped
    }

    /// Splits TOML content into lines, tolerating CRLF endings.
    private static func tomlLines(from content: String) -> [String] {
        guard !content.isEmpty else { return [] }
        var lines = content.components(separatedBy: "\n").map { line in
            line.hasSuffix("\r") ? String(line.dropLast()) : line
        }
        if lines.last == "" {
            lines.removeLast()
        }
        return lines
    }

    private static func tomlContent(from lines: [String]) -> String {
        guard !lines.isEmpty else { return "" }
        return lines.joined(separator: "\n") + "\n"
    }
}
