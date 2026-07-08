import Foundation

/// Resolves the Safari Technology Preview MCP server command for agent launches.
public enum SafariMCPServerConfig {
    /// The MCP server name used in generated agent configuration.
    public static let serverName = "safari-mcp-stp"

    /// Safari Technology Preview's bundled `safaridriver` path.
    public static let defaultDriverPath = "/Applications/Safari Technology Preview.app/Contents/MacOS/safaridriver"

    /// Returns the executable Safari MCP server driver path, or `nil` when unavailable.
    ///
    /// - Parameters:
    ///   - environment: Environment variables used for opt-out and path override.
    ///   - fileManager: Filesystem dependency used to verify executability.
    /// - Returns: An executable `safaridriver` path suitable for MCP stdio launch.
    public static func resolvedDriverPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String? {
        if environment["CMUX_SAFARI_MCP_DISABLED"] == "1" {
            return nil
        }

        let rawPath = environment["CMUX_SAFARI_MCP_DRIVER_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let path = rawPath?.isEmpty == false ? rawPath! : defaultDriverPath
        let expanded = (path as NSString).expandingTildeInPath
        guard fileManager.isExecutableFile(atPath: expanded) else { return nil }
        return expanded
    }

    /// Returns Codex `-c` overrides that register Safari's MCP stdio server.
    ///
    /// - Parameter driverPath: Executable `safaridriver` path.
    /// - Returns: TOML assignment strings for Codex's `mcp_servers` config.
    public static func codexConfigOverrides(driverPath: String) -> [String] {
        [
            "mcp_servers.\(serverName).command=\(tomlString(driverPath))",
            "mcp_servers.\(serverName).args=[\"--mcp\"]",
        ]
    }

    private static func tomlString(_ value: String) -> String {
        var escaped = ""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08: escaped += "\\b"
            case 0x09: escaped += "\\t"
            case 0x0A: escaped += "\\n"
            case 0x0C: escaped += "\\f"
            case 0x0D: escaped += "\\r"
            case 0x22: escaped += "\\\""
            case 0x5C: escaped += "\\\\"
            default:
                escaped.unicodeScalars.append(scalar)
            }
        }
        return "\"\(escaped)\""
    }
}
