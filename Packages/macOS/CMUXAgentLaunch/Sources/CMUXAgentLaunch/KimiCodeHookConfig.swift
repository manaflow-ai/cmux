import Foundation

/// Builds and removes cmux-owned Kimi Code hook blocks in TOML config files.
/// lint:allow namespace-type — stateless, dependency-free TOML text transform mirroring the grandfathered HermesAgentHookConfig/RovoDevHookConfig hook-config shape (baseline may only shrink); candidate for the shared marker-block helper consolidation.
public enum KimiCodeHookConfig {
    /// A Kimi Code hook event entry written as a TOML `[[hooks]]` table.
    public struct Event: Equatable, Sendable {
        /// The Kimi Code event name.
        public var name: String
        /// The complete command string to execute for the event.
        public var command: String
        /// The hook timeout in seconds.
        public var timeout: Int

        /// Creates a Kimi Code hook event.
        /// - Parameters:
        ///   - name: The Kimi Code event name.
        ///   - command: The complete command string to execute.
        ///   - timeout: The hook timeout in seconds.
        public init(name: String, command: String, timeout: Int) {
            self.name = name
            self.command = command
            self.timeout = timeout
        }
    }

    private static let beginMarker =
        "# cmux-kimi-hooks-7c3a9f12-4e8b-4d2a-9f15-6b8c0d1e2a3f begin"
    private static let endMarker =
        "# cmux-kimi-hooks-7c3a9f12-4e8b-4d2a-9f15-6b8c0d1e2a3f end"

    /// Returns TOML content with exactly one cmux-owned Kimi Code hooks block.
    /// - Parameters:
    ///   - events: Hook events to write, in output order.
    ///   - existing: Existing TOML config content.
    /// - Returns: The updated TOML content.
    public static func installing(events: [Event], in existing: String) -> String {
        var lines = tomlLines(from: existing)
        removeCmuxKimiHooksBlock(from: &lines)

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

    /// Returns TOML content after removing cmux-owned Kimi Code hooks blocks.
    /// - Parameter existing: Existing TOML config content.
    /// - Returns: The TOML content without cmux-owned Kimi Code hook blocks.
    public static func uninstalling(from existing: String) -> String {
        var lines = tomlLines(from: existing)
        removeCmuxKimiHooksBlock(from: &lines)
        return tomlContent(from: lines)
    }

    private static func hookTableLines(event: Event) -> [String] {
        return [
            "[[hooks]]",
            "event = \"\(tomlBasicStringContent(event.name))\"",
            "command = \"\(tomlBasicStringContent(event.command))\"",
            "timeout = \(event.timeout)",
            "",
        ]
    }

    private static func removeCmuxKimiHooksBlock(from lines: inout [String]) {
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

    private static func tomlLines(from content: String) -> [String] {
        guard !content.isEmpty else { return [] }
        var lines = content.components(separatedBy: "\n")
        if content.hasSuffix("\n"), lines.last == "" {
            lines.removeLast()
        }
        return lines
    }

    private static func tomlContent(from lines: [String]) -> String {
        guard !lines.isEmpty else { return "" }
        return lines.joined(separator: "\n") + "\n"
    }
}
