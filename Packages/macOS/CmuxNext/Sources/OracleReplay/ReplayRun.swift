import CmuxNextInputModel
import Foundation

/// The files one `oracle-replay --out DIR` run writes, in scripts/cmux-next/oracle/diff.py's formats:
/// - `receipt.json` and `checkpoints.jsonl`: a run directory (one `replay` checkpoint per journal whose snapshot is
///   the `debug.replay` result), so `diff.py BASE_OUT HEAD_OUT` compares two builds' reducers on the same journals
///   (the differential `journals` suite, p15-oracle.md section 3D);
/// - `divergence.json`: the `oracle-divergence-v1` document of the recording (side a) against this replay (side b),
///   with each journal's first divergence as diff.py reports one.
struct ReplayRun {
    struct Host: Encodable, Sendable {
        var name: String
        var os: String
        var osVersion: String
        var arch: String

        static func current() -> Host {
            let info = ProcessInfo.processInfo
            #if os(Linux)
            let os = "linux"
            #elseif os(macOS)
            let os = "mac"
            #else
            let os = "unknown"
            #endif
            #if arch(arm64)
            let arch = "arm64"
            #elseif arch(x86_64)
            let arch = "x86_64"
            #else
            let arch = "unknown"
            #endif
            return Host(name: info.hostName, os: os, osVersion: info.operatingSystemVersionString, arch: arch)
        }
    }

    private struct Receipt: Encodable {
        struct Case: Encodable {
            var suite = "journals"
            var result: String
        }

        var runId: String
        var sha: String
        var tool = "oracle-replay"
        var host: Host
        var cases: [String: Case]
    }

    private struct Checkpoint: Encodable {
        var `case`: String
        var step = "replay"
        var index = 0
        var checkpoint = "settled"
        var snapshot: InputReplay.Result
    }

    private struct RunHeader: Encodable {
        var path: String
        var runId: String
        var sha: String
        var host: Host
    }

    private struct Summary: Encodable {
        var cases: Int
        var equal: Int
        var explained = 0
        var divergent: Int
        var flaky = 0
        var skipped = 0
    }

    private struct Count: Encodable {
        var checkpoints: Int
        var pointers: Int
    }

    private struct CaseReport: Encodable {
        struct Results: Encodable {
            var a: String
            var b: String
        }

        private enum CodingKeys: String, CodingKey {
            case `case`, status, result, first
            case divergentCheckpoints = "divergent_checkpoints"
            case divergentPointers = "divergent_pointers"
        }

        var `case`: String
        var status: String
        var result: Results
        var divergentCheckpoints: Int
        var divergentPointers: Int
        var first: FirstDivergence?
    }

    /// diff.py's finding (`_finding`, the ui-workflow-corpus review-finding shape).
    private struct Finding: Encodable {
        var journey: String
        var step: String
        var severity = "S2"
        var expected: String
        var observed: String
        var source: String
        var environment: String
        var evidence: [String]
        var replay: String
        var confidence = "unconfirmed"
        var checkpoint: String
        var pointer: String
        var a: FirstDivergence.Value
        var b: FirstDivergence.Value
        var count: Count
    }

    private struct Divergences: Encodable {
        var schema = "oracle-divergence-v1"
        var verdict: String
        var hostPolicy = "same-host"
        var a: RunHeader
        var b: RunHeader
        var summary: Summary
        var divergences: [Finding]
        var cases: [CaseReport]
    }

    let replayed: [ReplayedJournal]
    let runID: String
    let sha: String
    let host: Host

    private let encoder = ReplayRun.jsonEncoder()

    init(replayed: [ReplayedJournal], runID: String, sha: String, host: Host) {
        self.replayed = replayed
        self.runID = runID
        self.sha = sha
        self.host = host
    }

    /// Sorted keys, as `debug.replay` encodes (DesyncReport.encoder): the same result gives the same bytes.
    static func jsonEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    func save(in directory: URL) throws(OracleReplayError) {
        do {
            // blocking-allow: host oracle tool, not the app; no app thread to block.
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw .unwritable(path: directory.path, reason: String(describing: error))
        }
        let cases = Dictionary(uniqueKeysWithValues: replayed.map { ($0.journal.caseID, Receipt.Case(result: $0.outcome)) })
        try writeJSON(Receipt(runId: runID, sha: sha, host: host, cases: cases), to: directory.appendingPathComponent("receipt.json"))
        var lines = Data()
        for journal in replayed {
            try lines.append(encode(Checkpoint(case: journal.journal.caseID, snapshot: journal.result)))
            lines.append(UInt8(ascii: "\n"))
        }
        try write(lines, to: directory.appendingPathComponent("checkpoints.jsonl"))
        try writeJSON(divergences(out: directory.path), to: directory.appendingPathComponent("divergence.json"))
    }

    private func divergences(out: String) -> Divergences {
        let divergent = replayed.filter(\.diverged)
        let recording = RunHeader(path: replayed.first.map { $0.journal.path } ?? "", runId: "recording",
                                  sha: replayed.lazy.compactMap { $0.journal.header?.sha }.first ?? "", host: host)
        return Divergences(
            verdict: divergent.isEmpty ? "pass" : "divergent",
            a: recording,
            b: RunHeader(path: out, runId: runID, sha: sha, host: host),
            summary: Summary(cases: replayed.count, equal: replayed.count - divergent.count, divergent: divergent.count),
            divergences: divergent.compactMap(finding),
            cases: replayed.map { journal in
                CaseReport(case: journal.journal.caseID, status: journal.diverged ? "divergent" : "equal",
                           result: .init(a: "Pass", b: journal.outcome),
                           divergentCheckpoints: journal.result.divergences, divergentPointers: journal.result.divergences,
                           first: journal.first)
            }
        )
    }

    private func finding(_ journal: ReplayedJournal) -> Finding? {
        guard let first = journal.first else { return nil }
        let evidence = first.lines.a.map { ["\(journal.journal.path)#\($0)"] } ?? [journal.journal.path]
        return Finding(
            journey: journal.journal.caseID,
            step: first.step,
            expected: "replay equals the recording at seq \(first.index) \(first.pointer)",
            observed: "recorded \(Self.text(first.a)) replayed \(Self.text(first.b))",
            source: sha,
            environment: runID,
            evidence: evidence,
            replay: "OracleReplay --replay-json \(journal.journal.path)",
            checkpoint: first.checkpoint,
            pointer: first.pointer,
            a: first.a,
            b: first.b,
            count: Count(checkpoints: journal.result.divergences, pointers: journal.result.divergences)
        )
    }

    static func text(_ value: FirstDivergence.Value) -> String {
        switch value {
        case .text(let text): text ?? "null"
        case .violations(let violations): violations.isEmpty ? "no violation" : violations.map(\.detail).joined(separator: "; ")
        }
    }

    func encode(_ value: some Encodable) throws(OracleReplayError) -> Data {
        do {
            return try encoder.encode(value)
        } catch {
            throw .unwritable(path: "(json)", reason: String(describing: error))
        }
    }

    private func writeJSON(_ value: some Encodable, to url: URL) throws(OracleReplayError) {
        try write(encode(value), to: url)
    }

    private func write(_ data: Data, to url: URL) throws(OracleReplayError) {
        do {
            // blocking-allow: host oracle tool, not the app; no app thread to block.
            try data.write(to: url, options: .atomic)
        } catch {
            throw .unwritable(path: url.path, reason: String(describing: error))
        }
    }
}
