// CmuxNextDaemon's generated request types (<Name>Request.generated.swift) are not in git: every build writes
// them from cmux-tui/spec/sdk-schema.json and cmux-tui/bindings/codegen/swift_app/bindings.json with
// swift_app/generate.py, which rewrites only changed files, so an incremental build recompiles nothing it did
// not change.
import Foundation
import PackagePlugin

@main
struct DaemonRequestsPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        // The package is Packages/macOS/CmuxNext; the generator and the schema are at the repo root.
        let repo = context.package.directoryURL.appending(path: "../../..").standardized
        let script = repo.appending(path: "cmux-tui/bindings/codegen/swift_app/generate.py")
        let out = context.pluginWorkDirectoryURL.appending(path: "Requests")
        return [
            .prebuildCommand(
                displayName: "Generate the daemon request types from cmux-tui/spec/sdk-schema.json",
                executable: URL(filePath: "/usr/bin/env"),
                // -B: the sandbox lets the plugin write only its work directory, so no __pycache__ beside the codegen.
                arguments: ["python3", "-I", "-B", script.path(percentEncoded: false), "--out", out.path(percentEncoded: false)],
                outputFilesDirectory: out
            ),
        ]
    }
}
