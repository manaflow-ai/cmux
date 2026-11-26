// A string table kept as one file per key (`<Table>.xcstrings.d/<key>.xcstrings`) is not in git as one catalog:
// two pull requests that each added a key to one catalog file conflicted on GitHub (scripts/cmux-next/string_catalogs.py
// has the numbers). Every build writes the target's tables from its directories into this plugin's work directory with
// scripts/cmux-next/string_catalogs.py build-target, which rewrites only a changed table, and SwiftPM and Xcode compile
// them as the target's resources.
import Foundation
import PackagePlugin

@main
struct StringCatalogsPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        // The package is Packages/macOS/CmuxNext; the script is at the repo root.
        let repo = context.package.directoryURL.appending(path: "../../..").standardized
        let script = repo.appending(path: "scripts/cmux-next/string_catalogs.py")
        let out = context.pluginWorkDirectoryURL.appending(path: "Tables")
        return [
            .prebuildCommand(
                displayName: "Build the string tables of \(target.name) from their one-file-per-key directories",
                executable: URL(filePath: "/usr/bin/env"),
                arguments: [
                    "python3", "-I", script.path(percentEncoded: false), "build-target",
                    target.directoryURL.path(percentEncoded: false), out.path(percentEncoded: false),
                ],
                outputFilesDirectory: out
            ),
        ]
    }
}
