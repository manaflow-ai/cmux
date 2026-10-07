import CmuxLinkBench
import Foundation

// cmux-link-bench --rig v1|v2-webrtc|v2-mem|v3|ref [--rtt-ms N] [--loss P]
//                 [--quick] [--only connect,rtt,rtt-bulk,flood,bulk,reconnect,roam]
//                 [--out results.json]
// One rig per process so the memory high-water mark belongs to that rig.

// lint:allow free-function: executable entry point helper.
func usage() -> Never {
    let rigs = BenchRigKind.allCases.map(\.rawValue).joined(separator: "|")
    let workloads = BenchWorkload.allCases.map(\.rawValue).joined(separator: ",")
    FileHandle.standardError.write(Data("""
    usage: cmux-link-bench --rig \(rigs) [--rtt-ms N] [--loss 0.01] [--quick] [--only \(workloads)] [--bulk-record BYTES] [--out file.json]
    --rtt-ms and --loss apply to the shapeable rigs (v2-mem, ref) only.

    """.utf8))
    exit(2)
}

var arguments = Array(CommandLine.arguments.dropFirst())
var rig: BenchRigKind?
var rtt = 0.0
var loss = 0.0
var quick = false
var only: Set<BenchWorkload>?
var output: String?
var bulkRecord = 64 * 1024
while !arguments.isEmpty {
    let flag = arguments.removeFirst()
    func value() -> String {
        guard !arguments.isEmpty else { usage() }
        return arguments.removeFirst()
    }
    switch flag {
    case "--rig": rig = BenchRigKind(rawValue: value())
    case "--rtt-ms": rtt = Double(value()) ?? 0
    case "--loss": loss = Double(value()) ?? 0
    case "--quick": quick = true
    case "--only": only = Set(value().split(separator: ",").compactMap { BenchWorkload(rawValue: String($0)) })
    case "--out": output = value()
    case "--bulk-record": bulkRecord = Int(value()) ?? bulkRecord
    default: usage()
    }
}
guard let rig else { usage() }

var spec = BenchSpec(rig: rig, rttMilliseconds: rtt, loss: loss, quick: quick, workloads: only)
spec.bulkRecordBytes = bulkRecord
let report = await BenchRunner(spec: spec).run { line in
    FileHandle.standardError.write(Data((line + "\n").utf8))
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let data = try encoder.encode(report)
if let output {
    try data.write(to: URL(fileURLWithPath: output))
} else {
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}
exit(report.errors.isEmpty ? 0 : 1)
