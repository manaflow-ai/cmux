// CmuxNextWireGen: the build-time generator of CmuxNextIPC's wire bindings
// (plans/cmux-next/chrome-parity/p05-ipc.md section 3.3, task 027).
//
// CmuxNextWireGenPlugin runs it with the two schema files as declared inputs, so the
// build reruns it only when one of them (or this tool) changes:
//
//   CmuxNextWireGen --sdk-schema cmux-tui/spec/sdk-schema.json \
//     --resource-operations cmux-tui/spec/resource-operations-v2.json \
//     --identity-output <plugin work dir>/WireSchemaIdentity+Built.generated.swift \
//     --method-table-output <plugin work dir>/MethodTable+Schema.swift \
//     --resource-output-dir <plugin work dir> --resource-operation-names terminal.input.write,... \
//     --types-output-dir <plugin work dir>
//
// The last pair writes ResourceOperations.swift and ResourceOperations+<family>.swift: typed
// requests for the named `cmux.protocol/2` operations (the plugin's appResourceOperations).
//
// For CmuxNextIPCTestSupport it writes only the fixture schema's `DaemonWireEvent` (task 022):
//
//   CmuxNextWireGen --sdk-schema cmux-tui/spec/fixtures/ipc-method-tables/sdk-schema.json \
//     --resource-operations cmux-tui/spec/fixtures/ipc-method-tables/resource-operations-v2.json \
//     --event-output <plugin work dir>/DaemonWireEvent+Fixture.swift --event-import CmuxNextIPC
//
// A run writes only the outputs it is given. Its outputs live only in the plugin work
// directory; nothing it writes is in git (scripts/ci/generated-files.json, `ipc-wire-swift`,
// status "build"). The Rust side is cmux-tui/crates/cmux-ipc/build.rs; both write the same
// identity values and the same method tables (the Swift table keeps only `clients: macos`
// methods). Later tasks (020-024) add their emitters next to IdentityEmitter, TableEmitter and
// EventEmitter, over the same files.

import Foundation

func run(_ argv: [String]) throws(WireGenError) {
    let arguments = try WireGenArguments(argv)
    let sdk = try SchemaInput(arguments.sdkSchema)
    let resource = try SchemaInput(arguments.resourceOperations)
    if let output = arguments.identityOutput {
        let emitter = try IdentityEmitter(
            sdk: SchemaFile<SDKSchemaHeader>(sdk),
            resource: SchemaFile<ResourceOperationsHeader>(resource)
        )
        try GeneratedFile(url: output).write(emitter.emit())
    }
    if let output = arguments.methodTableOutput {
        let table: TableEmitter
        do {
            table = try TableEmitter(sdkSchema: sdk.bytes, resourceOperations: resource.bytes)
        } catch {
            throw WireGenError.methodTable(error)
        }
        try GeneratedFile(url: output).write(table.source())
    }
    if let output = arguments.eventOutput {
        let events: EventEmitter
        do {
            events = try EventEmitter(sdkSchema: sdk.bytes, resourceOperations: resource.bytes)
        } catch {
            throw WireGenError.methodTable(error)
        }
        try GeneratedFile(url: output).write(events.source(importing: arguments.eventImport))
    }
    if let directory = arguments.resourceOutputDirectory {
        let files: [ResourceEmitter.File]
        do throws(ResourceEmitterError) {
            files = try ResourceEmitter(resourceOperations: resource.bytes, operations: arguments.resourceOperationNames)
                .files()
        } catch {
            throw WireGenError.resourceOperations(error)
        }
        for file in files {
            try GeneratedFile(url: directory.appending(path: file.name, directoryHint: .notDirectory)).write(file.text)
        }
    }
    if let directory = arguments.typesOutputDirectory {
        let types: [GeneratedSource]
        do {
            types = try TypeEmitter(sdkSchema: sdk.bytes).files()
        } catch {
            throw WireGenError.types(error)
        }
        // The plugin declared its outputs from the same WireTypeFiles rule; a file it did not
        // declare would not compile, so a difference fails here with the names.
        let declared = (try? WireTypeFiles(sdkSchema: sdk.bytes).fileNames) ?? []
        let written = types.map(\.fileName)
        guard declared == written else {
            let detail = "the plugin declares \(Set(declared).subtracting(written).sorted()) but TypeEmitter writes "
                + "\(Set(written).subtracting(declared).sorted()) instead"
            throw WireGenError.types(TypeSchemaError(path: "$", message: detail))
        }
        for file in types {
            try GeneratedFile(url: directory.appending(path: file.fileName, directoryHint: .notDirectory)).write(file.text)
        }
    }
}

do {
    try run(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("CmuxNextWireGen: \(error)\n".utf8))
    exit(1)
}
