import Foundation

enum AgentHookSetupStatus {
    static func hasConfiguredAgentHooks(
        homeDirectory: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        claudeCodeHooksEnabled: Bool = false
    ) -> Bool {
        if claudeCodeHooksEnabled {
            return true
        }

        let homeURL = URL(fileURLWithPath: homeDirectory, isDirectory: true)
        let candidateFiles = [
            homeURL.appendingPathComponent(".codex/hooks.json"),
            homeURL.appendingPathComponent(".codex/config.toml"),
            homeURL.appendingPathComponent(".grok/hooks/cmux-session.json"),
            homeURL.appendingPathComponent(".config/opencode/plugins/cmux-session.js"),
            homeURL.appendingPathComponent(".config/opencode/plugins/cmux-feed.js"),
            homeURL.appendingPathComponent(".pi/agent/extensions/cmux-session.ts"),
            homeURL.appendingPathComponent(".config/amp/plugins/cmux-session.ts"),
            homeURL.appendingPathComponent(".cursor/hooks.json"),
            homeURL.appendingPathComponent(".gemini/settings.json"),
            homeURL.appendingPathComponent(".gemini/config/hooks.json"),
            homeURL.appendingPathComponent(".rovodev/config.yml"),
            homeURL.appendingPathComponent(".hermes/config.yaml"),
            homeURL.appendingPathComponent(".copilot/config.json"),
            homeURL.appendingPathComponent(".codebuddy/settings.json"),
            homeURL.appendingPathComponent(".factory/settings.json"),
            homeURL.appendingPathComponent(".qoder/settings.json")
        ]

        let environmentFiles = [
            environment["CODEX_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("hooks.json") },
            environment["GROK_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("hooks/cmux-session.json") },
            environment["OPENCODE_CONFIG_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("plugins/cmux-session.js") },
            environment["PI_CODING_AGENT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("extensions/cmux-session.ts") },
            environment["HERMES_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("config.yaml") },
            environment["COPILOT_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("config.json") },
            environment["CODEBUDDY_CONFIG_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("settings.json") },
            environment["QODER_CONFIG_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("settings.json") }
        ].compactMap { $0 }

        let markerSubstrings = [
            "cmux hooks ",
            "\"$cmux_cli\" hooks ",
            "cmux-session",
            "cmux-feed-plugin-marker",
            "cmux-grok-hook-v2",
            "cmux-antigravity-hook-v2"
        ]
        for fileURL in candidateFiles + environmentFiles {
            guard fileManager.fileExists(atPath: fileURL.path),
                  let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
                continue
            }
            if markerSubstrings.contains(where: { text.contains($0) }) {
                return true
            }
        }

        let storeDirectory = homeURL.appendingPathComponent(".cmuxterm", isDirectory: true)
        guard let contents = try? fileManager.contentsOfDirectory(
            at: storeDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return false
        }
        return contents.contains { $0.lastPathComponent.hasSuffix("-hook-sessions.json") }
    }
}
