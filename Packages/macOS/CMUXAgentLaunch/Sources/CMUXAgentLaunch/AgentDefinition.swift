import Foundation

/// A single coding-agent catalog entry: the brand identity plus the process-name, path, and
/// argument tokens that let cmux recognize a running agent process as this agent.
///
/// This is pure catalog data, a `Sendable` value type. The matching/normalization logic that
/// consumes a catalog of these lives on ``AgentDetector``; this type holds no behavior beyond the
/// built-in catalog (``builtIns``), which `AgentDetector` uses as its default.
public struct AgentDefinition: Sendable, Equatable {
    /// Stable agent identifier (e.g. `"claude"`, `"codex"`), used as the aggregation key.
    public let id: String
    /// Human-facing agent name (e.g. `"Claude Code"`).
    public let displayName: String
    /// Optional asset-catalog icon name (e.g. `"AgentIcons/Claude"`), `nil` when the agent has no
    /// branded icon.
    public let assetName: String?
    /// `CMUX_AGENT_LAUNCH_KIND` values that identify this agent when present in the environment.
    public let launchKinds: [String]
    /// Executable basenames that directly identify this agent (process name, path, or argv[0]).
    public let directBasenames: [String]
    /// Argument-substring tokens (package specifiers, script paths) that identify this agent when it
    /// runs under a host interpreter (node/bun/etc.).
    public let argumentNeedles: [String]

    /// Creates a catalog entry.
    public init(
        id: String,
        displayName: String,
        assetName: String?,
        launchKinds: [String],
        directBasenames: [String],
        argumentNeedles: [String]
    ) {
        self.id = id
        self.displayName = displayName
        self.assetName = assetName
        self.launchKinds = launchKinds
        self.directBasenames = directBasenames
        self.argumentNeedles = argumentNeedles
    }

    /// The built-in coding-agent catalog. ``AgentDetector`` uses this as its default catalog.
    public static let builtIns: [AgentDefinition] = [
        AgentDefinition(
            id: "claude",
            displayName: "Claude Code",
            assetName: "AgentIcons/Claude",
            launchKinds: ["claude", "claudeteams", "claude-teams", "omc"],
            directBasenames: ["claude", "claude-code", "claude_code", "claude-teams", "omc"],
            argumentNeedles: [
                "claude-code",
                "claude_code",
                "claude-teams",
                "@anthropic-ai/claude-code",
                "oh-my-claude",
                "omc",
                "/.local/bin/claude",
                "/.local/share/claude/versions/",
                "/library/application support/claude/claude-code/",
            ]
        ),
        AgentDefinition(
            id: "codex",
            displayName: "Codex",
            assetName: "AgentIcons/Codex",
            launchKinds: ["codex", "omx"],
            directBasenames: ["codex", "omx"],
            argumentNeedles: ["codex", "@openai/codex", "oh-my-codex"]
        ),
        AgentDefinition(
            id: "grok",
            displayName: "Grok",
            assetName: nil,
            launchKinds: ["grok"],
            directBasenames: ["grok", "grok-macos-aarch64", "grok-macos-aarch"],
            argumentNeedles: ["grok", "grok-build", "@xai/grok"]
        ),
        AgentDefinition(
            id: "opencode",
            displayName: "OpenCode",
            assetName: "AgentIcons/OpenCode",
            launchKinds: ["opencode", "omo"],
            directBasenames: ["opencode", "opencode-ai", "open-code", "omo"],
            argumentNeedles: ["opencode", "opencode-ai", "open-code", "oh-my-openagent"]
        ),
        AgentDefinition(
            id: "omp",
            displayName: "OMP",
            assetName: nil,
            launchKinds: ["omp"],
            directBasenames: ["omp"],
            argumentNeedles: ["@oh-my-pi/pi-coding-agent"]
        ),
        AgentDefinition(
            id: "pi",
            displayName: "Pi",
            assetName: "AgentIcons/Pi",
            launchKinds: ["pi"],
            directBasenames: ["pi", "pi-coding-agent"],
            argumentNeedles: ["@mariozechner/pi-coding-agent", "pi-coding-agent"]
        ),
        AgentDefinition(
            id: "amp",
            displayName: "Amp",
            assetName: nil,
            launchKinds: ["amp"],
            directBasenames: ["amp"],
            argumentNeedles: ["@ampcode"]
        ),
        AgentDefinition(
            id: "cursor",
            displayName: "Cursor",
            assetName: nil,
            launchKinds: ["cursor"],
            directBasenames: ["cursor-agent"],
            argumentNeedles: ["cursor-agent"]
        ),
        AgentDefinition(
            id: "gemini",
            displayName: "Gemini",
            assetName: nil,
            launchKinds: ["gemini"],
            directBasenames: ["gemini"],
            argumentNeedles: ["gemini"]
        ),
        AgentDefinition(
            id: "kiro",
            displayName: "Kiro",
            assetName: nil,
            launchKinds: ["kiro"],
            directBasenames: ["kiro", "kiro-cli"],
            argumentNeedles: ["kiro", "kiro-cli"]
        ),
        AgentDefinition(
            id: "antigravity",
            displayName: "Antigravity",
            assetName: "AgentIcons/Antigravity",
            launchKinds: ["antigravity", "agy"],
            directBasenames: ["agy", "antigravity"],
            argumentNeedles: ["antigravity-cli", "antigravity"]
        ),
        AgentDefinition(
            id: "rovodev",
            displayName: "Rovo Dev",
            assetName: "AgentIcons/RovoDev",
            launchKinds: ["rovodev", "rovo"],
            directBasenames: ["rovodev"],
            argumentNeedles: ["rovodev"]
        ),
        AgentDefinition(
            id: "hermes-agent",
            displayName: "Hermes Agent",
            assetName: "AgentIcons/HermesAgent",
            launchKinds: ["hermes-agent"],
            directBasenames: ["hermes", "hermes-agent"],
            argumentNeedles: ["hermes-agent"]
        ),
        AgentDefinition(
            id: "copilot",
            displayName: "Copilot",
            assetName: nil,
            launchKinds: ["copilot"],
            directBasenames: ["copilot"],
            argumentNeedles: ["copilot"]
        ),
        AgentDefinition(
            id: "codebuddy",
            displayName: "CodeBuddy",
            assetName: nil,
            launchKinds: ["codebuddy"],
            directBasenames: ["codebuddy"],
            argumentNeedles: ["codebuddy"]
        ),
        AgentDefinition(
            id: "factory",
            displayName: "Factory",
            assetName: nil,
            launchKinds: ["factory"],
            directBasenames: ["droid", "factory"],
            argumentNeedles: ["factory"]
        ),
        AgentDefinition(
            id: "qoder",
            displayName: "Qoder",
            assetName: nil,
            launchKinds: ["qoder"],
            directBasenames: ["qoder", "qodercli"],
            argumentNeedles: ["qoder", "qodercli"]
        ),
    ]
}
