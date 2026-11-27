// The backdrop art records (CmuxNextDesign's BackdropArt+Entries.swift, `BackdropArt.entry`) are not in
// git: every build writes them from art/manifest.json with scripts/cmux-next/art/generate_backdrop_art.py
// --entries-out, which rewrites the file only when it changed, so an incremental build recompiles nothing.
import Foundation
import PackagePlugin

@main
struct BackdropArtEntriesPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        // The package is Packages/macOS/CmuxNext; the generator and art/manifest.json are at the repo root.
        let repo = context.package.directoryURL.appending(path: "../../..").standardized
        let script = repo.appending(path: "scripts/cmux-next/art/generate_backdrop_art.py")
        let out = context.pluginWorkDirectoryURL.appending(path: "BackdropArt")
        return [
            .prebuildCommand(
                displayName: "Generate the backdrop art records from art/manifest.json",
                executable: URL(filePath: "/usr/bin/env"),
                arguments: ["python3", "-I", script.path(percentEncoded: false), "--entries-out", out.path(percentEncoded: false)],
                outputFilesDirectory: out
            ),
        ]
    }
}
