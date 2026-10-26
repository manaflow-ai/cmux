// Runs CmuxNextWireGen for the target that uses this plugin, with the schema files as declared
// inputs and its outputs in the plugin work directory (plans/cmux-next/chrome-parity/p05-ipc.md
// section 3.3, task 027). CmuxNextIPC gets its wire bindings from cmux-tui/spec; CmuxNextIPCTests
// gets the fixture schema's `DaemonWireEvent` (task 022), so the emitted event decode is compiled
// and tested on every build. A build command, not a prebuild command: the build system reruns it
// only when an input changes, so a leaf Swift edit never regenerates. Nothing it writes is in git.

import Foundation
import PackagePlugin

@main
struct CmuxNextWireGenPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: any Target) async throws -> [Command] {
        // Packages/macOS/CmuxNext -> the repository root's cmux-tui/spec.
        let spec = context.package.directoryURL
            .appending(path: "../../../cmux-tui/spec", directoryHint: .isDirectory)
            .standardizedFileURL
        let tool = try context.tool(named: "CmuxNextWireGen")
        let work = context.pluginWorkDirectoryURL
        if target.name == "CmuxNextIPCTests" {
            return [Self.fixtureEvents(tool: tool.url, spec: spec, work: work, target: target.name)]
        }
        return [Self.schemaBindings(tool: tool.url, spec: spec, work: work, target: target.name)]
    }

    /// The identity and `MethodTable.schema` (task 023) of cmux-tui/spec. `DaemonWireEvent+Schema.swift`
    /// joins them once TypeEmitter's payload types build (p05-ipc-020, then p05-ipc-195).
    private static func schemaBindings(tool: URL, spec: URL, work: URL, target: String) -> Command {
        let sdkSchema = spec.appending(path: "sdk-schema.json", directoryHint: .notDirectory)
        let resourceOperations = spec.appending(path: "resource-operations-v2.json", directoryHint: .notDirectory)
        let identity = work.appending(path: "WireSchemaIdentity+Built.generated.swift", directoryHint: .notDirectory)
        let methodTable = work.appending(path: "MethodTable+Schema.swift", directoryHint: .notDirectory)
        return .buildCommand(
            displayName: "CmuxNextWireGen: wire bindings for \(target) from cmux-tui/spec",
            executable: tool,
            arguments: [
                "--sdk-schema", sdkSchema.path(percentEncoded: false),
                "--resource-operations", resourceOperations.path(percentEncoded: false),
                "--identity-output", identity.path(percentEncoded: false),
                "--method-table-output", methodTable.path(percentEncoded: false),
            ],
            inputFiles: [sdkSchema, resourceOperations],
            outputFiles: [identity, methodTable]
        )
    }

    /// `DaemonWireEvent` of the method-table fixture schema, importing CmuxNextIPC's `WireEventSet`;
    /// its payload types are declared in WireEventSetTests.swift.
    private static func fixtureEvents(tool: URL, spec: URL, work: URL, target: String) -> Command {
        let fixtures = spec.appending(path: "fixtures/ipc-method-tables", directoryHint: .isDirectory)
        let sdkSchema = fixtures.appending(path: "sdk-schema.json", directoryHint: .notDirectory)
        let resourceOperations = fixtures.appending(path: "resource-operations-v2.json", directoryHint: .notDirectory)
        let events = work.appending(path: "DaemonWireEvent+Fixture.swift", directoryHint: .notDirectory)
        return .buildCommand(
            displayName: "CmuxNextWireGen: fixture DaemonWireEvent for \(target)",
            executable: tool,
            arguments: [
                "--sdk-schema", sdkSchema.path(percentEncoded: false),
                "--resource-operations", resourceOperations.path(percentEncoded: false),
                "--event-output", events.path(percentEncoded: false),
                "--event-import", "CmuxNextIPC",
            ],
            inputFiles: [sdkSchema, resourceOperations],
            outputFiles: [events]
        )
    }
}
