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
//     --types-output-dir <plugin work dir>
//
// Its outputs live only in the plugin work directory; nothing it writes is in git
// (scripts/ci/generated-files.json, `ipc-wire-swift`, status "build"). The Rust side
// is cmux-tui/crates/cmux-ipc/build.rs; both write the same identity values and the same
// method tables (the Swift table keeps only `clients: macos` methods). Later
// tasks (020-024) add their emitters next to IdentityEmitter and TableEmitter, over the same files.

import Foundation

func run(_ argv: [String]) throws(WireGenError) {
    let arguments = try WireGenArguments(argv)
    let sdk = try SchemaFile<SDKSchemaHeader>(arguments.sdkSchema)
    let resource = try SchemaFile<ResourceOperationsHeader>(arguments.resourceOperations)
    let emitter = IdentityEmitter(sdk: sdk, resource: resource)
    try GeneratedFile(url: arguments.identityOutput).write(emitter.emit())
    let table: TableEmitter
    do {
        table = try TableEmitter(sdkSchema: sdk.bytes, resourceOperations: resource.bytes)
    } catch {
        throw WireGenError.methodTable(error)
    }
    try GeneratedFile(url: arguments.methodTableOutput).write(table.source())
    let types: [GeneratedSource]
    do {
        types = try TypeEmitter(sdkSchema: sdk.bytes).files()
    } catch {
        throw WireGenError.types(error)
    }
    for file in types {
        try GeneratedFile(url: arguments.typesOutputDirectory.appending(path: file.fileName, directoryHint: .notDirectory))
            .write(file.text)
    }
}

do {
    try run(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("CmuxNextWireGen: \(error)\n".utf8))
    exit(1)
}
