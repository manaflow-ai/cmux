// The Swift design scale (CmuxNextDesignTokens' DesignScale.generated.swift) is not in git: every build
// writes it from schemas/design-scale/design-scale.json with scripts/cmux-next/gen-design-scale-swift.py,
// which rewrites the file only when its text changed, so an incremental build recompiles nothing.
import Foundation
import PackagePlugin

@main
struct DesignScalePlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        // The package is Packages/macOS/CmuxNext; the generator and its input are at the repo root.
        let repo = context.package.directoryURL.appending(path: "../../..").standardized
        let script = repo.appending(path: "scripts/cmux-next/gen-design-scale-swift.py")
        let out = context.pluginWorkDirectoryURL.appending(path: "DesignScale")
        return [
            .prebuildCommand(
                displayName: "Generate the Swift design scale from schemas/design-scale",
                executable: URL(filePath: "/usr/bin/env"),
                arguments: ["python3", "-I", script.path(percentEncoded: false), "--swift-out", out.path(percentEncoded: false)],
                outputFilesDirectory: out
            ),
        ]
    }
}
