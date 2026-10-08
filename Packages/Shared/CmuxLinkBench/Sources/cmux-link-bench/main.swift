import CmuxLinkBench
import CmuxLinkDirect
import Darwin
import Dispatch
import Foundation

// cmux-link-bench --rig v1|v2-webrtc|v2-mem|v3|ref [--rtt-ms N] [--loss P]
//                 [--quick] [--only connect,rtt,rtt-bulk,flood,bulk,reconnect,roam]
//                 [--bulk-record BYTES] [--out results.json]
// cmux-link-bench serve [--address HOST] [--bind HOST] [--port N]
//                 [--device-key BASE64 | --allow-any] [--descriptor-out file.json]
//
// The regular command runs both peers in one process. `serve` is the F2 Mac
// half: it prints a pinned descriptor and hosts the source/echo service for an
// iOS DEV client over the real direct carrier.

// lint:allow free-function: executable entry point helper.
func usage() -> Never {
    let rigs = BenchRigKind.allCases.map(\.rawValue).joined(separator: "|")
    let workloads = BenchWorkload.allCases.map(\.rawValue).joined(separator: ",")
    FileHandle.standardError.write(Data("""
    usage: cmux-link-bench --rig \(rigs) [--rtt-ms N] [--loss 0.01] [--quick] [--only \(workloads)] [--bulk-record BYTES] [--out file.json]
           cmux-link-bench serve [--address HOST] [--bind HOST] [--port N]
             [--device-key BASE64 | --allow-any] [--descriptor-out file.json]
           cmux-link-bench client --descriptor file.json --out result.json
             --manifest manifest.json --source-commit SHA [--identity-file key.bin] [--quick]
    --rtt-ms and --loss apply to the shapeable rigs (v2-mem, ref) only.
    `serve` is a development-only direct-carrier listener; prefer a paired
    --device-key on a shared network. The descriptor is JSON schema
    cmux-link-bench-serve/1. The shared split-client library also supports iOS.

    """.utf8))
    exit(2)
}

// lint:allow free-function: executable entry point helper.
func argumentValue(_ arguments: inout [String]) -> String {
    guard !arguments.isEmpty else { usage() }
    return arguments.removeFirst()
}

// lint:allow free-function: executable entry point helper.
func writeJSON<T: Encodable>(_ value: T, to path: String?) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    if let path {
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    } else {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

// lint:allow free-function: executable entry point helper.
func runServe(arguments initial: [String]) async throws {
    var arguments = initial
    var address = "127.0.0.1"
    var bind: String? = "127.0.0.1"
    var port: UInt16 = 0
    var hostID = "cmux-link-bench"
    var rig = "direct"
    var deviceKey: DirectPublicKey?
    var allowAny = false
    var descriptorOut: String?
    while !arguments.isEmpty {
        switch arguments.removeFirst() {
        case "--address": address = argumentValue(&arguments)
        case "--bind": bind = argumentValue(&arguments)
        case "--port": port = UInt16(argumentValue(&arguments)) ?? 0
        case "--host-id": hostID = argumentValue(&arguments)
        case "--rig":
            rig = argumentValue(&arguments)
            guard rig == "direct" || rig == "v3" else { usage() }
        case "--device-key":
            let text = argumentValue(&arguments)
            guard let key = DirectPublicKey(base64: text) else { usage() }
            deviceKey = key
        case "--allow-any": allowAny = true
        case "--descriptor-out": descriptorOut = argumentValue(&arguments)
        case "--help", "-h": usage()
        default: usage()
        }
    }
    guard allowAny || deviceKey != nil else {
        FileHandle.standardError.write(Data("serve requires --device-key or --allow-any\n".utf8))
        exit(2)
    }
    var allowed: Set<DirectPublicKey> = []
    if let deviceKey { allowed.insert(deviceKey) }
    _ = rig
    let server = BenchSplitServer(configuration: BenchSplitServerConfiguration(
        hostID: hostID, advertisedAddress: address, localAddress: bind,
        port: port, allowAnyDevice: allowAny, allowedDevices: allowed
    ))
    // The signal source bridges the process lifecycle to structured async
    // cleanup. No polling and no abandoned checked continuation.
    let (signals, sink) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let sources = [SIGINT, SIGTERM].map { code in
        let source = DispatchSource.makeSignalSource(signal: code, queue: .global())
        source.setEventHandler { sink.yield(()) }
        source.resume()
        return source
    }
    defer {
        for source in sources { source.cancel() }
        sink.finish()
        signal(SIGINT, SIG_DFL)
        signal(SIGTERM, SIG_DFL)
    }
    do {
        let descriptor = try await server.start()
        try writeJSON(descriptor, to: descriptorOut)
        for await _ in signals { break }
        await server.stop()
    } catch {
        await server.stop()
        throw error
    }
}

// lint:allow free-function: executable entry point helper.
func runClient(arguments initial: [String]) async throws -> Bool {
    var arguments = initial
    var descriptorPath: String?
    var identityPath: String?
    var output: String?
    var manifestPath: String?
    var sourceCommit: String?
    var quick = false
    while !arguments.isEmpty {
        switch arguments.removeFirst() {
        case "--descriptor": descriptorPath = argumentValue(&arguments)
        case "--identity-file": identityPath = argumentValue(&arguments)
        case "--out": output = argumentValue(&arguments)
        case "--manifest": manifestPath = argumentValue(&arguments)
        case "--source-commit": sourceCommit = argumentValue(&arguments)
        case "--quick": quick = true
        default: usage()
        }
    }
    guard let descriptorPath, let output, let manifestPath, let sourceCommit else { usage() }
    let descriptor = try BenchServeDescriptor.decode(Data(contentsOf: URL(fileURLWithPath: descriptorPath)))
    let identity: DirectIdentity
    if let identityPath {
        identity = try DirectIdentity(privateKeyRepresentation: Data(contentsOf: URL(fileURLWithPath: identityPath)))
    } else {
        identity = DirectIdentity()
    }
    let client = try BenchSplitClient(descriptor: descriptor, deviceIdentity: identity)
    var spec = BenchSpec(rig: .v3, quick: quick)
    spec.bulkRecordBytes = descriptor.bulkRecordBytes
    // Validate artifact paths and provenance before starting the workload.
    let manifest = try BenchResultManifest.singleResult(
        name: "split-direct", sourceCommit: sourceCommit,
        recordedAt: ISO8601DateFormatter().string(from: Date()),
        description: "F2 split direct benchmark; CPU and memory are client-process measurements",
        resultURL: URL(fileURLWithPath: output), manifestURL: URL(fileURLWithPath: manifestPath),
        group: "split-direct"
    )
    let report = try await client.run(spec: spec) { line in
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
    try writeJSON(report, to: output)
    try manifest.write(to: URL(fileURLWithPath: manifestPath))
    return report.errors.isEmpty
}

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "client" {
    _ = arguments.removeFirst()
    do { exit(try await runClient(arguments: arguments) ? 0 : 1) } catch {
        FileHandle.standardError.write(Data(("client failed: \(error)\n").utf8))
        exit(1)
    }
} else if arguments.first == "serve" {
    _ = arguments.removeFirst()
    do {
        try await runServe(arguments: arguments)
    } catch {
        FileHandle.standardError.write(Data(("serve failed: \(error)\n").utf8))
        exit(1)
    }
} else {
    var rig: BenchRigKind?
    var rtt = 0.0
    var loss = 0.0
    var quick = false
    var only: Set<BenchWorkload>?
    var output: String?
    var bulkRecord = 64 * 1024
    while !arguments.isEmpty {
        let flag = arguments.removeFirst()
        switch flag {
        case "--rig": rig = BenchRigKind(rawValue: argumentValue(&arguments))
        case "--rtt-ms": rtt = Double(argumentValue(&arguments)) ?? 0
        case "--loss": loss = Double(argumentValue(&arguments)) ?? 0
        case "--quick": quick = true
        case "--only":
            only = Set(argumentValue(&arguments).split(separator: ",").compactMap { BenchWorkload(rawValue: String($0)) })
        case "--out": output = argumentValue(&arguments)
        case "--bulk-record": bulkRecord = Int(argumentValue(&arguments)) ?? bulkRecord
        case "--help", "-h": usage()
        default: usage()
        }
    }
    guard let rig else { usage() }
    var spec = BenchSpec(rig: rig, rttMilliseconds: rtt, loss: loss, quick: quick, workloads: only)
    spec.bulkRecordBytes = bulkRecord
    let report = await BenchRunner(spec: spec).run { line in
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
    do { try writeJSON(report, to: output) } catch {
        FileHandle.standardError.write(Data(("failed to write report: \(error)\n").utf8))
        exit(1)
    }
    exit(report.errors.isEmpty ? 0 : 1)
}
