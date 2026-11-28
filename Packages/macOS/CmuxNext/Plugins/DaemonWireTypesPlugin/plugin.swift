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
        let pick = repo.appending(path: "cmux-tui/bindings/codegen/swift_app/pick-python.sh")
        let out = context.pluginWorkDirectoryURL.appending(path: "Requests")
        return [
            .prebuildCommand(
                displayName: "Generate the CmuxNextDaemon request types from cmux-tui/spec/sdk-schema.json",
                // The interpreter pick is a file beside the generator, not `sh -c TEXT`: SwiftPM echoes a failed
                // prebuild command's arguments, and inline text put the pick's own "needs Python" line into every
                // plugin failure's log, so a codegen error read as a missing Python (bb23166636a, 2026-11-28).
                // pick-python.sh says how it finds a 3.10+ Python with Xcode's PATH=/usr/bin:/bin.
                executable: URL(filePath: "/bin/sh"),
                arguments: [pick.path(percentEncoded: false), script.path(percentEncoded: false),
                            out.path(percentEncoded: false)],
                outputFilesDirectory: out
            ),
        ]
    }
}
