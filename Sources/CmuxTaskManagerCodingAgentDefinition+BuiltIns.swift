import CmuxTerminalCore
import Foundation

extension CmuxTaskManagerCodingAgentDefinition {
    static let builtIns: [CmuxTaskManagerCodingAgentDefinition] = [
        .init(id: "claude", displayName: "Claude Code", assetName: "AgentIcons/Claude",
              launchKinds: ["claude", "claudeteams", "claude-teams", "omc"],
              directBasenames: ["claude", "claude.exe", "claude-code", "claude_code", "claude-teams", "omc"],
              argumentNeedles: ["claude-code", "claude_code", "claude-teams", "@anthropic-ai/claude-code", "oh-my-claude", "omc", "/.local/bin/claude", "/.local/share/claude/versions/", "/library/application support/claude/claude-code/"]),
        .init(id: "codex", displayName: "Codex", assetName: "AgentIcons/Codex",
              launchKinds: ["codex", "omx"], directBasenames: ["codex", "omx"],
              argumentNeedles: ["codex", "@openai/codex", "oh-my-codex"]),
        .init(id: "grok", displayName: "Grok", assetName: nil,
              launchKinds: ["grok"], directBasenames: ["grok", "grok-macos-aarch64", "grok-macos-aarch"],
              argumentNeedles: ["grok", "grok-build", "@xai/grok"]),
        .init(id: "opencode", displayName: "OpenCode", assetName: "AgentIcons/OpenCode",
              launchKinds: ["opencode", "omo"], directBasenames: ["opencode", "opencode-ai", "open-code", "omo"],
              argumentNeedles: ["opencode", "opencode-ai", "open-code", "oh-my-openagent"]),
        .init(id: "omp", displayName: "OMP", assetName: "AgentIcons/Pi",
              launchKinds: ["omp"], directBasenames: ["omp"], argumentNeedles: ["@oh-my-pi/pi-coding-agent"]),
        .init(id: "campfire", displayName: "Campfire", assetName: nil,
              launchKinds: ["campfire"], directBasenames: ["campfire"],
              argumentNeedles: ["packages/session/bin/campfire.ts", "packages/session/dist/campfire"]),
        .init(id: "pi", displayName: "Pi", assetName: "AgentIcons/Pi",
              launchKinds: ["pi"], directBasenames: ["pi", "pi-coding-agent"],
              argumentNeedles: ["@mariozechner/pi-coding-agent", "pi-coding-agent"]),
        .init(id: "amp", displayName: "Amp", assetName: nil,
              launchKinds: ["amp"], directBasenames: ["amp"], argumentNeedles: ["@ampcode"]),
        .init(id: "cursor", displayName: "Cursor", assetName: nil,
              launchKinds: ["cursor"], directBasenames: ["cursor-agent"], argumentNeedles: ["cursor-agent"]),
        .init(id: "gemini", displayName: "Gemini", assetName: nil,
              launchKinds: ["gemini"], directBasenames: ["gemini"], argumentNeedles: ["gemini"]),
        .init(id: "kiro", displayName: "Kiro", assetName: nil,
              launchKinds: ["kiro"], directBasenames: ["kiro", "kiro-cli"], argumentNeedles: ["kiro", "kiro-cli"]),
        .init(id: "antigravity", displayName: "Antigravity", assetName: "AgentIcons/Antigravity",
              launchKinds: ["antigravity", "agy"], directBasenames: ["agy", "antigravity"],
              argumentNeedles: ["antigravity-cli", "antigravity"]),
        .init(id: "rovodev", displayName: "Rovo Dev", assetName: "AgentIcons/RovoDev",
              launchKinds: ["rovodev", "rovo"], directBasenames: ["rovodev"], argumentNeedles: ["rovodev"]),
        .init(id: "hermes-agent", displayName: "Hermes Agent", assetName: "AgentIcons/HermesAgent",
              launchKinds: ["hermes-agent"], directBasenames: ["hermes", "hermes-agent"], argumentNeedles: ["hermes-agent"]),
        .init(id: "copilot", displayName: "Copilot", assetName: nil,
              launchKinds: ["copilot"], directBasenames: ["copilot"], argumentNeedles: ["copilot"]),
        .init(id: "codebuddy", displayName: "CodeBuddy", assetName: nil,
              launchKinds: ["codebuddy"], directBasenames: ["codebuddy"], argumentNeedles: ["codebuddy"]),
        .init(id: "factory", displayName: "Factory", assetName: nil,
              launchKinds: ["factory"], directBasenames: ["droid", "factory"], argumentNeedles: ["factory"]),
        .init(id: "qoder", displayName: "Qoder", assetName: nil,
              launchKinds: ["qoder"], directBasenames: ["qoder", "qodercli"], argumentNeedles: ["qoder", "qodercli"]),
        .init(
            id: "ollama",
            displayName: String(localized: "agent.ollama.displayName", defaultValue: "Ollama"),
            assetName: nil,
            launchKinds: ["ollama"],
            directBasenames: ["ollama"],
            // No argument needles: a bare "ollama" token plus the "run"
            // prefix would also match wrappers such as `npm run ollama`.
            // Identity comes from the executable basename or launch kind.
            argumentNeedles: [],
            requiredArgumentPrefix: ["run"],
            promptTurnDetection: PromptLineTurnDetectionConfiguration(
                prompt: ">>> ",
                waitingPromptSuffixes: ["Send a message (/? for help)"]
            )
        ),
    ]
}
