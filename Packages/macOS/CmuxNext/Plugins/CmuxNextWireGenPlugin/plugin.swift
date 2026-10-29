// Runs CmuxNextWireGen for the target that uses this plugin, with the schema files as declared
// inputs and its outputs in the plugin work directory (plans/cmux-next/chrome-parity/p05-ipc.md
// section 3.3, task 027). CmuxNextIPC gets its wire bindings from cmux-tui/spec;
// CmuxNextIPCTestSupport gets the fixture schema's `DaemonWireEvent` (task 022), so the emitted
// event decode is compiled and tested (CmuxNextIPCTests) on every build. Apply it to regular
// targets only: a test product links the executables its test targets reach, the host tool too.
// A build command, not a prebuild command: the build system reruns it only when an input
// changes, so a leaf Swift edit never regenerates. Nothing it writes is in git.

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
        if target.name == "CmuxNextIPCTestSupport" {
            return [Self.fixtureEvents(tool: tool.url, spec: spec, work: work, target: target.name)]
        }
        return [try Self.schemaBindings(tool: tool.url, spec: spec, work: work, target: target.name)]
    }

    /// The identity, `MethodTable.schema` (task 023) and the app's `cmux.protocol/2` requests
    /// (task 024) of cmux-tui/spec. `DaemonWireEvent+Schema.swift` joins them once TypeEmitter's
    /// payload types build (then p05-ipc-195).
    private static func schemaBindings(tool: URL, spec: URL, work: URL, target: String) throws -> Command {
        let sdkSchema = spec.appending(path: "sdk-schema.json", directoryHint: .notDirectory)
        let resourceOperations = spec.appending(path: "resource-operations-v2.json", directoryHint: .notDirectory)
        let identity = work.appending(path: "WireSchemaIdentity+Built.generated.swift", directoryHint: .notDirectory)
        let methodTable = work.appending(path: "MethodTable+Schema.swift", directoryHint: .notDirectory)
        // ResourceEmitter writes one file of shared types and errors and one per operation family.
        let resourceFiles = resourceFileNames(appResourceOperations).map {
            work.appending(path: $0, directoryHint: .notDirectory)
        }
        // The wire types (task 020, TypeEmitter): the support files and one file per named type
        // the app's commands reach, listed by WireTypeFiles, the source CmuxNextWireGen names its
        // files with (this directory's WireTypeFiles.swift is a symlink to it).
        let wireTypes = try WireTypeFiles(sdkSchema: Data(contentsOf: sdkSchema)).fileNames.map {
            work.appending(path: $0, directoryHint: .notDirectory)
        }
        return .buildCommand(
            displayName: "CmuxNextWireGen: wire bindings for \(target) from cmux-tui/spec",
            executable: tool,
            arguments: [
                "--sdk-schema", sdkSchema.path(percentEncoded: false),
                "--resource-operations", resourceOperations.path(percentEncoded: false),
                "--identity-output", identity.path(percentEncoded: false),
                "--method-table-output", methodTable.path(percentEncoded: false),
                "--resource-output-dir", work.path(percentEncoded: false),
                "--resource-operation-names", appResourceOperations.joined(separator: ","),
                "--types-output-dir", work.path(percentEncoded: false),
            ],
            inputFiles: [sdkSchema, resourceOperations],
            outputFiles: [identity, methodTable] + resourceFiles + wireTypes
        )
    }

    /// The files ResourceEmitter writes for `operations`: `ResourceOperations.swift`, then
    /// `ResourceOperations+<family>.swift` per family (the name before the first dot), sorted.
    /// CmuxNextWireGen names them the same way (`ResourceEmitter.fileName(family:)`), and a name
    /// declared here that it does not write fails the build.
    private static func resourceFileNames(_ operations: [String]) -> [String] {
        let families = Set(operations.map { name in String(name.prefix { $0 != "." }) })
        return ["ResourceOperations.swift"] + families.sorted().map { "ResourceOperations+\($0).swift" }
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
