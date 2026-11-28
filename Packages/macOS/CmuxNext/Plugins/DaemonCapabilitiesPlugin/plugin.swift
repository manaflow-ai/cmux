// CmuxNextDaemon's `enum DaemonCapability` is not in git: every build writes it from
// cmux-tui/spec/gui-capabilities.json with scripts/cmux-next/gen-daemon-capabilities.py, which rewrites
// the file only when its bytes change, so an incremental build recompiles nothing it did not change.
import Foundation
import PackagePlugin

@main
struct DaemonCapabilitiesPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        // The package is Packages/macOS/CmuxNext; the generator and its input are at the repo root.
        let repo = context.package.directoryURL.appending(path: "../../..").standardized
        let script = repo.appending(path: "scripts/cmux-next/gen-daemon-capabilities.py")
        let out = context.pluginWorkDirectoryURL.appending(path: "DaemonCapabilities")
        return [
            .prebuildCommand(
                displayName: "Generate DaemonCapability from cmux-tui/spec/gui-capabilities.json",
                executable: URL(filePath: "/usr/bin/env"),
                arguments: ["python3", "-I", script.path(percentEncoded: false), "--swift-out", out.path(percentEncoded: false)],
                outputFilesDirectory: out
            ),
        ]
    }
}
