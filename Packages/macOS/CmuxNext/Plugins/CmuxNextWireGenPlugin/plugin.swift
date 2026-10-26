// Runs CmuxNextWireGen for the target that uses this plugin (CmuxNextIPC), with the two
// schema files as declared inputs and its outputs in the plugin work directory
// (plans/cmux-next/chrome-parity/p05-ipc.md section 3.3, task 027). A build command,
// not a prebuild command: the build system reruns it only when an input changes, so a
// leaf Swift edit never regenerates. Nothing it writes is in git.

import Foundation
import PackagePlugin

@main
struct CmuxNextWireGenPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: any Target) async throws -> [Command] {
        // Packages/macOS/CmuxNext -> the repository root's cmux-tui/spec.
        let spec = context.package.directoryURL
            .appending(path: "../../../cmux-tui/spec", directoryHint: .isDirectory)
            .standardizedFileURL
        let sdkSchema = spec.appending(path: "sdk-schema.json", directoryHint: .notDirectory)
        let resourceOperations = spec.appending(path: "resource-operations-v2.json", directoryHint: .notDirectory)
        let identity = context.pluginWorkDirectoryURL
            .appending(path: "WireSchemaIdentity+Built.generated.swift", directoryHint: .notDirectory)
        // `MethodTable.schema` (task 023, CmuxNextWireGen's TableEmitter).
        let methodTable = context.pluginWorkDirectoryURL
            .appending(path: "MethodTable+Schema.swift", directoryHint: .notDirectory)
        // The wire types (task 020, TypeEmitter): the support files and one file per named type
        // the app's commands reach, listed by WireTypeFiles, the source CmuxNextWireGen names its
        // files with (this directory's WireTypeFiles.swift is a symlink to it).
        let wireTypes = try WireTypeFiles(sdkSchema: Data(contentsOf: sdkSchema)).fileNames.map {
            context.pluginWorkDirectoryURL.appending(path: $0, directoryHint: .notDirectory)
        }
        let tool = try context.tool(named: "CmuxNextWireGen")
        return [
            .buildCommand(
                displayName: "CmuxNextWireGen: wire bindings for \(target.name) from cmux-tui/spec",
                executable: tool.url,
                arguments: [
                    "--sdk-schema", sdkSchema.path(percentEncoded: false),
                    "--resource-operations", resourceOperations.path(percentEncoded: false),
                    "--identity-output", identity.path(percentEncoded: false),
                    "--method-table-output", methodTable.path(percentEncoded: false),
                    "--types-output-dir", context.pluginWorkDirectoryURL.path(percentEncoded: false),
                ],
                inputFiles: [sdkSchema, resourceOperations],
                outputFiles: [identity, methodTable] + wireTypes
            ),
        ]
    }
}
