// The settings Swift (CmuxNextSettings' Schema/*.generated.swift) is not in git (RFD 0048): every
// build writes it from schemas/settings with scripts/cmux-next/gen-settings-sources.py, which
// rewrites only changed files, so an incremental build recompiles nothing it did not change.
import Foundation
import PackagePlugin

@main
struct SettingsSchemaPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        // The package is Packages/macOS/CmuxNext; the generator and its inputs are at the repo root.
        let repo = context.package.directoryURL.appending(path: "../../..").standardized
        let script = repo.appending(path: "scripts/cmux-next/gen-settings-sources.py")
        let out = context.pluginWorkDirectoryURL.appending(path: "Schema")
        return [
            .prebuildCommand(
                displayName: "Generate the settings Swift from schemas/settings",
                executable: URL(filePath: "/usr/bin/env"),
                arguments: ["python3", "-I", script.path(percentEncoded: false), "--swift-out", out.path(percentEncoded: false)],
                outputFilesDirectory: out
            ),
        ]
    }
}
