// CmuxNextWireGen: the build-time generator of CmuxNextIPC's wire bindings
// (plans/cmux-next/chrome-parity/p05-ipc.md section 3.3, task 027).
//
// CmuxNextWireGenPlugin runs it with the two schema files as declared inputs, so the
// build reruns it only when one of them (or this tool) changes:
//
//   CmuxNextWireGen --sdk-schema cmux-tui/spec/sdk-schema.json \
//     --resource-operations cmux-tui/spec/resource-operations-v2.json \
//     --identity-output <plugin work dir>/WireSchemaIdentity+Built.generated.swift
//
// Its outputs live only in the plugin work directory; nothing it writes is in git
// (scripts/ci/generated-files.json, `ipc-wire-swift`, status "build"). The Rust side
// is cmux-tui/crates/cmux-ipc/build.rs; both write the same identity values. Later
// tasks (020-024) add their emitters next to IdentityEmitter, over the same files.

import Foundation

func run(_ argv: [String]) throws(WireGenError) {
    let arguments = try WireGenArguments(argv)
    let sdk = try SchemaFile<SDKSchemaHeader>(arguments.sdkSchema)
    let resource = try SchemaFile<ResourceOperationsHeader>(arguments.resourceOperations)
    let emitter = IdentityEmitter(sdk: sdk, resource: resource)
    try GeneratedFile(url: arguments.identityOutput).write(emitter.emit())
}

do {
    try run(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("CmuxNextWireGen: \(error)\n".utf8))
    exit(1)
}
