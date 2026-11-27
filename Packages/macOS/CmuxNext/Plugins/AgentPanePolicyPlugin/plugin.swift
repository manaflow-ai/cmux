// CmuxNextAgentPane's relay policy tables (AcpmuxPaneMethods+Policy.generated.swift) are not in git
// (RFD 0048): every build writes them from cmux-tui/crates/cmux-agent-pane-policy/policy.json, the
// copy the Rust policy crate embeds, with scripts/cmux-next/gen-agent-pane-policy-swift.py, which
// rewrites the file only when its text changed, so an incremental build recompiles nothing.
import Foundation
import PackagePlugin

@main
struct AgentPanePolicyPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        // The package is Packages/macOS/CmuxNext; the generator and policy.json are at the repo root.
        let repo = context.package.directoryURL.appending(path: "../../..").standardized
        let script = repo.appending(path: "scripts/cmux-next/gen-agent-pane-policy-swift.py")
        let out = context.pluginWorkDirectoryURL.appending(path: "Policy")
        return [
            .prebuildCommand(
                displayName: "Generate the agent pane relay policy Swift from policy.json",
                executable: URL(filePath: "/usr/bin/env"),
                arguments: ["python3", "-I", script.path(percentEncoded: false), "--swift-out", out.path(percentEncoded: false)],
                outputFilesDirectory: out
            ),
        ]
    }
}
