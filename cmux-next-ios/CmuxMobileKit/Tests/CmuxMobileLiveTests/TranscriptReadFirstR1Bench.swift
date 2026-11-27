import CmuxMobileAgentChat
import Foundation
import Testing
@testable import CmuxMobileLive

/// R1 for the agent chat transcript: tap to the first frame of a chat the phone kept, with the
/// link cut, read from ``AgentTranscriptCache``'s disk entry (Leo, 2026-11-22: "like im sure theres
/// a hell of s lot more value in being able to read nigh instantly as much as possible").
///
/// A leg of `scripts/measure/ios-network-conditions.sh surfaces=transcript`, in the shape of the
/// Rust chat leg (`cmux-mobile-core/tests/read_first_r1.rs`): one `NETCOND` row per run with
/// surface `transcript`, profile `no-link@1`, phase `cold|warm`, scale `1x|10x|100x`, metric `r1_ms`.
/// The clock runs from the tap (a new hub source, as `LiveCoordinator` builds one with no tree)
/// to the first frame: the chat store holding its kept turns.
///
/// - cold: a fresh cache on a folder of 64 kept chats (the target, then 63 written after it), so
///   the head file comes off disk; warm: the same cache opened again (its memory, as a reopen).
/// - scale: 1x/10x/100x is 60/600/6000 turns of history handed to the cache, as the source keeps
///   them (its newest ``AgentTranscriptCache/recordLimit`` x 2, from a prompt).
/// - duress: two threads rewrite the other 63 chats' files the whole time, spinners load all but
///   three cores, and answers run 3 KB instead of 200 B.
///
/// Off unless `CMUX_TRANSCRIPT_R1_BENCH=1`; `NETCOND_MODE` (links|duress, default duress),
/// `NETCOND_RUNS`, `NETCOND_SCALES` (comma list of 1x,10x,100x), `NETCOND_SEED_BASE` as the harness
/// sets them. `scripts/measure/swift-test-bench.sh ... enable=CMUX_TRANSCRIPT_R1_BENCH` runs it too.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(30))) struct TranscriptReadFirstR1Bench {
    nonisolated static let env = ProcessInfo.processInfo.environment
    // nonisolated: `.enabled(if:)` reads it from a Sendable closure, off the main actor.
    nonisolated static var enabled: Bool { env["CMUX_TRANSCRIPT_R1_BENCH"] == "1" }

    static let summary = AgentSessionSummary(id: "s7", name: "Fix", harness: "codex", agentName: "Codex", cwd: "/tmp/w",
                                             workspaceTitle: "w", macName: "mini", macID: "mac1", accountID: "acct")
    static let others = 63

    /// Turn `n`'s five records, its answer `answer` bytes long.
    static func turn(_ n: Int, answer: Int) -> [JSONValue] {
        let seq = n * 5 + 1
        let text = String(repeating: "word \(n % 10) ", count: max(1, answer / 7))
        return [
            #"{"sessionId":"s1","seq":\#(seq),"at":1,"dir":"mux","kind":"user_message","msg":{"text":"prompt \#(n)","promptId":"p\#(n)","turnId":"t\#(n)"}}"#,
            #"{"sessionId":"s1","seq":\#(seq + 1),"at":2,"dir":"mux","kind":"turn_started","msg":{"turnId":"t\#(n)"}}"#,
            #"{"sessionId":"s1","seq":\#(seq + 2),"at":3,"dir":"in","kind":"agent_message_chunk","msg":{"method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"\#(text)"}}}}}"#,
            #"{"sessionId":"s1","seq":\#(seq + 3),"at":3,"dir":"in","kind":"agent_message_chunk","msg":{"method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"\#(n)"}}}}}"#,
            #"{"sessionId":"s1","seq":\#(seq + 4),"at":4,"dir":"mux","kind":"turn_result","msg":{"status":"completed","turnId":"t\#(n)"}}"#,
        ].compactMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
    }

    /// What the source hands the cache for a chat of `turns` turns: its newest records, bounded
    /// as `keep` bounds them, from a prompt; `earlier` when older ones were cut.
    static func kept(turns: Int, answer: Int, limit: Int) -> (records: [JSONValue], earlier: Bool) {
        let bound = limit * 2, perTurn = 5
        let first = max(0, turns - bound / perTurn)
        let records = (first..<turns).flatMap { turn($0, answer: answer) }
        return (AgentTranscriptCache.fromPrompt(Array(records.suffix(bound))), first > 0)
    }

    static func key(_ tab: String) -> String { AgentTranscriptCache.key(accountID: "acct", macID: "mac1", tabID: tab)! }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    /// Load for duress: writers rewrite the other chats' files (full and head) in place, as saves
    /// of other chats do; spinners keep all but three cores busy.
    static func startLoad(files: [(URL, Data)], stop: Flag) -> [Thread] {
        var threads: [Thread] = []
        for w in 0..<2 {
            let mine = files.enumerated().filter { $0.offset % 2 == w }.map(\.element)
            threads.append(Thread {
                while !stop.isSet {
                    for (url, data) in mine where !stop.isSet { try? data.write(to: url, options: .atomic) }
                }
            })
        }
        let spinners = max(0, ProcessInfo.processInfo.activeProcessorCount - 3)
        for _ in 0..<spinners {
            threads.append(Thread {
                var x: UInt64 = 1
                while !stop.isSet { for _ in 0..<100_000 { x = x &* 6364136223846793005 &+ 1442695040888963407 } }
                if x == 0 { print("") }
            })
        }
        threads.forEach { $0.start() }
        return threads
    }

    /// One open: tap (new hub, no link) to the store holding turns. Nil if none came in 5 s.
    static func open(_ cache: AgentTranscriptCache) async -> Double? {
        let clock = ContinuousClock(), start = clock.now
        let hub = AcpmuxHub()
        hub.transcriptCache = cache
        let store = AgentChatStore(source: hub.source(sessionID: "s1", summary: summary))
        let deadline = start + .seconds(5)
        while store.turns.isEmpty, clock.now < deadline { await Task.yield() }
        guard !store.turns.isEmpty else { return nil }
        let elapsed = clock.now - start
        return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    }

    static func row(_ phase: String, _ scale: String, _ metric: String, _ value: Double, run: Int, seed: Int) {
        print(#"NETCOND {"surface":"transcript","profile":"no-link@1","phase":"\#(phase)","scale":"\#(scale)","metric":"\#(metric)","value":\#(String(format: "%.3f", value)),"run":\#(run),"seed":\#(seed)}"#)
    }

    @Test(.enabled(if: TranscriptReadFirstR1Bench.enabled)) func transcriptR1() async throws {
        let duress = (Self.env["NETCOND_MODE"] ?? "duress") == "duress"
        let runs = Int(Self.env["NETCOND_RUNS"] ?? "") ?? 20
        let seedBase = Int(Self.env["NETCOND_SEED_BASE"] ?? "") ?? 0
        let scales = (Self.env["NETCOND_SCALES"] ?? "1x,10x,100x").split(separator: ",").map(String.init)
        let answer = duress ? 3000 : 200
        var rows = 0
        for scale in scales {
            guard let factor = Int(scale.dropLast()), scale.hasSuffix("x") else { continue }
            let turns = 60 * factor
            for run in 0..<runs {
                let seed = seedBase + run
                let directory = FileManager.default.temporaryDirectory
                    .appending(path: "netcond-transcript-\(UUID().uuidString)", directoryHint: .isDirectory)
                defer { try? FileManager.default.removeItem(at: directory) }
                let writer = AgentTranscriptCache(directory: directory, writeDelay: .milliseconds(0))
                let target = Self.kept(turns: turns, answer: answer, limit: writer.recordLimit)
                writer.save(Self.key("s7"), sessionID: "s1", earlier: target.earlier, records: target.records)
                writer.flush()
                let other = Self.kept(turns: 120, answer: answer, limit: writer.recordLimit)
                for i in 0..<Self.others {
                    writer.save(Self.key("o\(i)"), sessionID: "o\(i)", earlier: other.earlier, records: other.records)
                }
                writer.flush()
                guard writer.firstScreen(Self.key("s7")) != nil || writer.cached(Self.key("s7")) != nil,
                      FileManager.default.fileExists(atPath: writer.headFile(for: Self.key("s7")).path) else {
                    print("NETCOND-ERROR transcript \(scale) run \(run): the target chat was not kept on disk")
                    continue
                }
                let stop = Flag()
                var threads: [Thread] = []
                if duress {
                    let files = (0..<Self.others).flatMap { i -> [(URL, Data)] in
                        let k = Self.key("o\(i)")
                        return [writer.file(for: k), writer.headFile(for: k)].compactMap { url in
                            (try? Data(contentsOf: url)).map { (url, $0) }
                        }
                    }
                    threads = Self.startLoad(files: files, stop: stop)
                }
                defer { stop.set() }

                let cache = AgentTranscriptCache(directory: directory)
                if let cold = await Self.open(cache) {
                    Self.row("cold", scale, "r1_ms", cold, run: run, seed: seed)
                    rows += 1
                } else {
                    print("NETCOND-ERROR transcript cold \(scale) run \(run): no kept turns in the first frame")
                }
                // The open's own refill of the whole copy lands before the reopen, as on a phone.
                _ = await cache.load(Self.key("s7"))
                if let warm = await Self.open(cache) {
                    Self.row("warm", scale, "r1_ms", warm, run: run, seed: seed)
                    rows += 1
                } else {
                    print("NETCOND-ERROR transcript warm \(scale) run \(run): no kept turns in the first frame")
                }
                Self.row("cold", scale, "bytes_down", 0, run: run, seed: seed)
                stop.set()
                while threads.contains(where: { $0.isExecuting }) { try? await Task.sleep(for: .milliseconds(1)) }
            }
        }
        if rows == 0 { print("NETCOND-ERROR transcript: no r1_ms rows") }
        #expect(rows > 0)
    }
}
