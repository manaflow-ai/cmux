import SwiftUI

/// Shared pixel-art "pet": one little walking creature per running coding
/// agent. Used both by Sleepy Mode (the full-screen scene in `SleepyFaceView`)
/// and by the sidebar "agent is working" indicator, so the two stay
/// pixel-for-pixel identical and only have to evolve in one place.
enum PixelAgentPet {
    /// Color bucket for a running agent, matching the Sleepy Mode palette.
    enum Species: String, CaseIterable, Sendable, Equatable {
        case claude
        case codex
        case opencode
        case pi
        case ollama
        case other

        /// Maps an agent-hook status key (e.g. `"claude_code"`) to a species.
        /// Less-common agents intentionally fall back to `.other` so the palette
        /// stays small and readable at glyph size.
        init(agentStatusKey key: String) {
            switch key {
            case "claude_code": self = .claude
            case "codex": self = .codex
            case "opencode": self = .opencode
            case "pi": self = .pi
            case "ollama": self = .ollama
            default: self = .other
            }
        }

        var color: Color {
            switch self {
            case .claude: return Color(red: 0.96, green: 0.55, blue: 0.26)
            case .codex: return Color(red: 0.62, green: 0.86, blue: 0.97)
            case .opencode: return Color(red: 0.45, green: 0.86, blue: 0.55)
            case .pi: return Color(red: 0.70, green: 0.52, blue: 0.97)
            case .ollama: return Color(red: 0.93, green: 0.89, blue: 0.80)
            case .other: return Color(red: 1.0, green: 0.70, blue: 0.80)
            }
        }
    }

    /// Draws one walking pixel pet into `ctx`, its top-left body cell at
    /// `(x, y)`. The tail nub sits one cell before `x` when `facingRight`, so
    /// callers should leave a one-cell margin on the leading side.
    static func draw(
        in ctx: inout GraphicsContext,
        x: CGFloat,
        y: CGFloat,
        cell: CGFloat,
        color: Color,
        step: Int,
        facingRight: Bool
    ) {
        let ink = Color(red: 0.12, green: 0.13, blue: 0.20)
        func put(_ col: Int, _ row: Int, _ c: Color) {
            ctx.fill(
                Path(CGRect(x: x + CGFloat(col) * cell, y: y + CGFloat(row) * cell, width: cell, height: cell)),
                with: .color(c)
            )
        }
        // Body (rows 1-3, cols 0-6) with softened top corners.
        for col in 0...6 {
            for row in 1...3 {
                if row == 1 && (col == 0 || col == 6) { continue }
                put(col, row, color)
            }
        }
        // Ears + tail nub.
        put(1, 0, color)
        put(5, 0, color)
        put(facingRight ? -1 : 7, 1, color)
        // Eye on the leading side.
        put(facingRight ? 5 : 1, 2, ink)
        // Legs alternate as it walks.
        if step == 0 {
            put(1, 4, color); put(5, 4, color)
        } else {
            put(2, 4, color); put(4, 4, color)
        }
    }
}

/// Presentation helpers for the sidebar "agent is working" indicator.
enum SidebarWorkingAgentPresentation {
    /// Deterministic priority so a workspace running several agents at once
    /// still shows a single, stable pet. Claude leads (it is the feature's
    /// primary case), then the other first-class species; anything else falls
    /// back to alphabetical order.
    private static let priorityOrder = ["claude_code", "codex", "opencode", "pi"]

    /// The one agent whose pet the row should show, given every agent key that
    /// is currently reporting `.running` in the workspace.
    static func primaryStatusKey(among keys: Set<String>) -> String? {
        for key in priorityOrder where keys.contains(key) {
            return key
        }
        return keys.sorted().first
    }

    /// Human-readable brand name for the tooltip. Agent brand names are proper
    /// nouns and are intentionally not localized; only the surrounding sentence
    /// (the "… is working" part) is.
    static func displayName(forStatusKey key: String) -> String {
        switch key {
        case "claude_code": return "Claude"
        case "codex": return "Codex"
        case "opencode": return "OpenCode"
        case "pi": return "Pi"
        case "amp": return "Amp"
        case "antigravity": return "Antigravity"
        case "codebuddy": return "CodeBuddy"
        case "copilot": return "Copilot"
        case "cursor": return "Cursor"
        case "factory": return "Factory"
        case "gemini": return "Gemini"
        case "grok": return "Grok"
        case "hermes-agent": return "Hermes Agent"
        case "kiro": return "Kiro"
        case "qoder": return "Qoder"
        case "rovodev": return "Rovo Dev"
        default:
            return key
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .capitalized
        }
    }
}
