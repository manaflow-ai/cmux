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
        // The wire types (task 020, TypeEmitter): one file per command family, named from
        // the schema's `families` table the same way TypeEmitter.fileNames names them.
        let wireTypes = try Self.wireTypeFileNames(sdkSchema: sdkSchema).map {
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

    /// TypeEmitter.fileNames(commandFamilies:): the support file, then one file per
    /// command family (ids 0x01-0x5F) and `unframed`, sorted by family name, each
    /// `WireTypes+<UpperCamelCase family>.swift`. A plugin cannot link the tool's
    /// code, so this is its twin; CmuxNextWireGen writes exactly these files.
    static func wireTypeFileNames(sdkSchema: URL) throws -> [String] {
        let document = try JSONSerialization.jsonObject(with: Data(contentsOf: sdkSchema))
        let families = (document as? [String: Any])?["families"] as? [String: Any] ?? [:]
        let commandFamilies = families.compactMap { name, value -> String? in
            guard let id = (value as? [String: Any])?["id"] as? Int, (0x01...0x5F).contains(id) else { return nil }
            return name
        }
        let words = { (family: String) in
            family.split(whereSeparator: { "-_. ".contains($0) }).map { word -> String in
                switch word {
                case "id": "ID"
                case "ids": "IDs"
                default: word.prefix(1).uppercased() + word.dropFirst()
                }
            }.joined()
        }
        return ["WireTypes+Support.swift"] + (commandFamilies + ["unframed"]).sorted().map { family in
            let name = words(family)
            return "WireTypes+\(name.first?.isNumber == true ? "_" + name : name).swift"
        }
    }
}
