// The CmuxNextDaemon request types that cmux-tui/bindings/codegen/swift_app/bindings.json lists are not in
// git (RFD 0048): every build writes them from cmux-tui/spec/sdk-schema.json with
// cmux-tui/bindings/codegen/swift_app/generate.py, which rewrites only changed files, so an incremental build
// recompiles nothing it did not change. They go to the plugin's work directory, never the target's own folder
// (SwiftPM would compile a second copy there).
import Foundation
import PackagePlugin

@main
struct DaemonWireTypesPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        // The package is Packages/macOS/CmuxNext; the generator and the schema are at the repo root.
        let repo = context.package.directoryURL.appending(path: "../../..").standardized
        let script = repo.appending(path: "cmux-tui/bindings/codegen/swift_app/generate.py")
        let out = context.pluginWorkDirectoryURL.appending(path: "Requests")
        return [
            .prebuildCommand(
                displayName: "Generate the CmuxNextDaemon request types from cmux-tui/spec/sdk-schema.json",
                executable: URL(filePath: "/usr/bin/env"),
                // -B: no __pycache__ beside the generator (a plugin may write only its work directory).
                arguments: ["python3", "-I", "-B", script.path(percentEncoded: false), "--out", out.path(percentEncoded: false)],
                outputFilesDirectory: out
            ),
        ]
    }
}
