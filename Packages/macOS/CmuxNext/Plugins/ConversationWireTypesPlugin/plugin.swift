import Foundation
import PackagePlugin

/// Generates CmuxNextDaemon's conversation wire types (the `conversation-*` and `cloud-*`
/// request and result structs) from cmux-tui/spec/sdk-schema.json before each build, so the
/// Swift is not a hand-kept mirror of the Rust protocol and is not in git
/// (scripts/cmux-next/gen-conversation-wire.py, scripts/cmux-next/conversation-wire.json).
@main
struct ConversationWireTypesPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        let repo = context.package.directoryURL.appending(path: "../../..").standardized
        let script = repo.appending(path: "scripts/cmux-next/gen-conversation-wire.py")
        let out = context.pluginWorkDirectoryURL.appending(path: "ConversationWire")
        return [
            .prebuildCommand(
                displayName: "Generate the conversation wire Swift from cmux-tui/spec/sdk-schema.json",
                executable: URL(filePath: "/usr/bin/env"),
                arguments: ["python3", "-I", script.path(percentEncoded: false), "--swift-out", out.path(percentEncoded: false)],
                outputFilesDirectory: out
            ),
        ]
    }
}
