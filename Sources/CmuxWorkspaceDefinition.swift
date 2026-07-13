import Foundation

struct CmuxWorkspaceDefinition: Codable, Sendable, Hashable {
    var name: String?
    var cwd: String?
    var color: String?
    /// Terminal background color (`#RRGGBB`) applied via OSC 11 to every
    /// terminal the workspace launches.
    var terminalBackground: String?
    /// Terminal foreground color (`#RRGGBB`) applied via OSC 10 to every
    /// terminal the workspace launches.
    var terminalForeground: String?
    /// User-defined environment variables inherited by every shell spawned in the
    /// workspace (issue #5995). Managed `CMUX_*` variables always win.
    var env: [String: String]?
    /// Bootstrap command sent to the workspace's first terminal before that
    /// terminal's own surface `command`. Other panes do not wait for it.
    var setup: String?
    var layout: CmuxLayoutNode?

    init(
        name: String? = nil,
        cwd: String? = nil,
        color: String? = nil,
        terminalBackground: String? = nil,
        terminalForeground: String? = nil,
        env: [String: String]? = nil,
        setup: String? = nil,
        layout: CmuxLayoutNode? = nil
    ) {
        self.name = name
        self.cwd = cwd
        self.color = color
        self.terminalBackground = terminalBackground
        self.terminalForeground = terminalForeground
        self.env = env
        self.setup = setup
        self.layout = layout
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        env = try container.decodeIfPresent([String: String].self, forKey: .env)
        if let rawSetup = try container.decodeIfPresent(String.self, forKey: .setup) {
            let trimmed = rawSetup.trimmingCharacters(in: .whitespacesAndNewlines)
            setup = trimmed.isEmpty ? nil : trimmed
        } else {
            setup = nil
        }
        layout = try container.decodeIfPresent(CmuxLayoutNode.self, forKey: .layout)

        if let rawColor = try container.decodeIfPresent(String.self, forKey: .color) {
            let defaults = decoder.userInfo[.cmuxWorkspaceColorDefaults] as? UserDefaults ?? .standard
            guard let normalized = WorkspaceTabColorSettings.resolvedColorHex(rawColor, defaults: defaults) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .color,
                    in: container,
                    debugDescription: "Invalid color \"\(rawColor)\". Expected 6-digit hex format (#RRGGBB) or a workspace color name"
                )
            }
            color = normalized
        } else {
            color = nil
        }

        terminalBackground = try Self.decodeTerminalColor(from: container, forKey: .terminalBackground)
        terminalForeground = try Self.decodeTerminalColor(from: container, forKey: .terminalForeground)
    }

    private static func decodeTerminalColor(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> String? {
        guard let raw = try container.decodeIfPresent(String.self, forKey: key) else { return nil }
        guard let normalized = WorkspaceTabColorSettings.normalizedHex(raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "Invalid terminal color \"\(raw)\". Expected 6-digit hex format (#RRGGBB)"
            )
        }
        return normalized
    }

    /// Shell command that applies `terminalBackground`/`terminalForeground` via
    /// OSC 11/10, delivered on the same path as the `setup` command. The hex
    /// values are re-normalized so the interpolation stays shell-safe.
    var terminalColorCommand: String? {
        var parts: [String] = []
        if let hex = terminalBackground.flatMap(WorkspaceTabColorSettings.normalizedHex) {
            parts.append("printf '\\033]11;%s\\007' '\(hex)'")
        }
        if let hex = terminalForeground.flatMap(WorkspaceTabColorSettings.normalizedHex) {
            parts.append("printf '\\033]10;%s\\007' '\(hex)'")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "; ")
    }
}
