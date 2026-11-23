import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The host's share of the daemon -> page hop of the agent chat, per history page and per stream
/// record: the inbound pass (`AcpmuxRequestIds.toPage`: the duplicate-key check, the top-level scan,
/// and the parse and id swap of a reply) and the push the main thread builds
/// (`AgentPaneTransportEvent.script`, the default host's `evaluateJavaScript` text). The payloads
/// are the public chat-sim replay's records (webviews/test/fixtures/chat-sim), cut the way acpmux
/// cuts its pages: an attach page of at most 400 records or 128 KiB, an older page of at most 2,000
/// records or 1 MiB, and single `_acpmux/event` records of 350-700 B.
///
/// Runs only with CMUX_PANE_TRANSPORT_BENCH=1, as one fleet measurement step; the same file
/// measures base and head (`scripts/measure/swift-test-bench.sh` with `restore_from`, release):
///
///     cmux-ci run --class exclusive --script scripts/measure/swift-test-bench.sh --ref SHA \
///       --arg Packages/macOS/CmuxNext --arg AgentPaneBridgeHopBench --arg config=release \
///       --arg enable=CMUX_PANE_TRANSPORT_BENCH [--arg restore_from=BASE \
///       --arg restore=Sources/CmuxNextAgentPane/AcpmuxRequestIds.swift,Sources/CmuxNextAgentPane/AcpmuxPaneSocket.swift]
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_PANE_TRANSPORT_BENCH"] == "1"))
struct AgentPaneBridgeHopBench {
    /// The replay's records, one JSON object a line.
    static let records: [String] = {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("webviews/test/fixtures/chat-sim/replay-lane-session.ndjson")
        let text = (try? String(contentsOf: fixture, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }()

    /// An `_acpmux/events`-shaped reply of the first records up to `count` and `bytes`.
    static func page(id: Int, count: Int, bytes: Int) -> String {
        var chosen: [String] = []
        var size = 0
        for record in records {
            if chosen.count >= count || size + record.utf8.count + 1 > bytes { break }
            chosen.append(record)
            size += record.utf8.count + 1
        }
        return #"{"jsonrpc":"2.0","id":\#(id),"result":{"events":["# + chosen.joined(separator: ",") + #"],"more":true,"lastSeq":\#(chosen.count)}}"#
    }

    static func median(_ runs: Int, _ body: () -> Void) -> Double {
        for _ in 0..<max(2, runs / 10) { body() }
        var samples: [Double] = []
        for _ in 0..<runs {
            let start = ContinuousClock.now
            body()
            let elapsed = ContinuousClock.now - start
            samples.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
        }
        samples.sort()
        return samples[samples.count / 2]
    }

    static func report(_ stage: String, _ payload: String, bytes: Int, ms: Double) {
        print(String(format: "PANE-HOP stage=%@ payload=%@ bytes=%d ms=%.4f MBps=%.1f",
                     stage, payload, bytes, ms, Double(bytes) / 1e6 / (ms / 1e3)))
    }

    @Test func theHostShareOfTheHop() throws {
        try #require(Self.records.count > 2_000, "the chat-sim replay fixture is missing")
        // Replies: the inbound pass for its page's method, then the main thread's push text.
        for (name, method, count, bytes, runs) in [("attach-128KiB", "_acpmux/attach", 400, 128 << 10, 200),
                                                   ("older-1MiB", "_acpmux/events", 2_000, 1 << 20, 40)] {
            let ids = AcpmuxRequestIds()
            let warm = max(2, runs / 10)
            // The relay counts its ids up from 1: each sample's reply is written beforehand.
            let texts = (1...(warm + runs)).map { Self.page(id: $0, count: count, bytes: bytes) }
            var forwarded: [String] = []
            var samples: [Double] = []
            for (index, text) in texts.enumerated() {
                _ = ids.begin(pageID: "17", method: method)
                let start = ContinuousClock.now
                let inbound = ids.toPage(text)
                let elapsed = ContinuousClock.now - start
                switch inbound {
                case .drop, .close: Issue.record("\(name) dropped")
                case .page(let fresh, _, _): forwarded = [fresh]
                default: forwarded = [text]
                }
                if index >= warm { samples.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000) }
            }
            samples.sort()
            Self.report("inbound.toPage", "\(name) \(method)", bytes: texts[0].utf8.count, ms: samples[samples.count / 2])
            let script = Self.median(runs) { _ = AgentPaneTransportEvent(connection: 3, frames: forwarded, closed: nil).script }
            Self.report("main.script", name, bytes: texts[0].utf8.count, ms: script)
        }
        // Stream records: `_acpmux/event` notifications, one at a time and as a full flush.
        let stream = Self.records.filter { (350...700).contains($0.utf8.count) }
            .map { #"{"jsonrpc":"2.0","method":"_acpmux/event","params":\#($0)}"# }
        for (name, frames, runs) in [("record-x1", Array(stream.prefix(1)), 5_000), ("records-x512", Array(stream.prefix(512)), 100)] {
            let ids = AcpmuxRequestIds()
            let bytes = frames.reduce(0) { $0 + $1.utf8.count }
            let inbound = Self.median(runs) { for frame in frames { _ = ids.toPage(frame) } }
            Self.report("inbound.toPage", name, bytes: bytes, ms: inbound)
            let script = Self.median(runs) { _ = AgentPaneTransportEvent(connection: 3, frames: frames, closed: nil).script }
            Self.report("main.script", name, bytes: bytes, ms: script)
        }
    }
}
