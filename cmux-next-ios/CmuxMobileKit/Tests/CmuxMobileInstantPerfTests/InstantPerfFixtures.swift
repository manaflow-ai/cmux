import CmuxMobileChief
import CmuxMobileTransport
import Foundation

// The instant-list bench's data: seeded, deterministic generators, each in a SMALL and a GOD
// size, built lazily in memory the first time a test asks (never checked in). See
// cmux-next-ios/design/instant-perf.md.
//
// - Home inbox (`home-inbox` reply bytes, as the Mac's owner sends them): 20 rows vs 5,000 rows,
//   with pins, Chiefs working, long Markdown previews and six months of activity dates.
// - Agent chat (acpmux records, the exact `{sessionId, seq, at, dir, kind, msg}` shape the fake
//   hubs in CmuxMobileLiveTests use): ~40 records vs 50,000 records with tool outputs up to
//   2 MB (logs and diffs), subagents nested 5 deep, 200 image parts and timestamps across six
//   months. The last 2 MB log sits about 60 records before the end (a long session's last
//   command is often the one that printed the most): the open's byte cap stops short of it,
//   and the first older page reads it.
//
// Run: swift test --package-path cmux-next-ios/CmuxMobileKit --filter CmuxMobileInstantPerfTests

/// SplitMix64: the same numbers on every machine and every run.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func int(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &self) }
    mutating func chance(_ percent: Int) -> Bool { int(0...99) < percent }
}

enum InstantPerfSize: String, Sendable, CaseIterable { case small, god }

/// Words for generated prose: no quote or backslash, so generated text is JSON-safe as is.
private let words = ["the", "dialer", "retries", "with", "backoff", "relay", "worker", "session", "cache", "list",
                     "render", "frame", "budget", "token", "stream", "replay", "page", "cursor", "seq", "attach",
                     "Mac", "phone", "agent", "Chief", "build", "tests", "pass", "fail", "fix", "merge", "ship",
                     "latency", "p95", "scroll", "row", "inbox", "pin", "unread", "subagent", "diff", "log"]

private func sentence(_ rng: inout SeededRandom, words count: Int) -> String {
    (0..<count).map { _ in words[rng.int(0...(words.count - 1))] }.joined(separator: " ")
}

/// A sentence of a length picked from `range` (one access to `rng`, never two overlapping).
private func sentence(_ rng: inout SeededRandom, words range: ClosedRange<Int>) -> String {
    let count = rng.int(range)
    return sentence(&rng, words: count)
}

/// Markdown as agents write it: bold, code spans, links, bullets and a fenced block.
/// `\n` here is the two-character JSON escape: the text goes into a JSON string literal as is.
private func markdown(_ rng: inout SeededRandom, bytes range: ClosedRange<Int>) -> String {
    let bytes = rng.int(range)
    var out = "**Done (#\(rng.int(1...9999))).** "
    while out.utf8.count < bytes {
        switch rng.int(0...4) {
        case 0: out += "- \(sentence(&rng, words: 4...12)) `code_\(rng.int(1...99))`\\n"
        case 1: out += "\\n```swift\\nlet value = cache.page(\(rng.int(1...400)))\\n```\\n"
        case 2: out += "[Details](https://cmux.com/d/\(rng.int(1...9999))) \(sentence(&rng, words: 8)). "
        default: out += "\(sentence(&rng, words: 8...24)). "
        }
    }
    return out
}

// MARK: - Home inbox

enum HomeInboxFixture {
    static func rowCount(_ size: InstantPerfSize) -> Int { size == .small ? 20 : 5_000 }

    /// The `home-inbox` reply line (`{"ok":true,"data":{"rows":[...]}}`), cached per size.
    static func wire(_ size: InstantPerfSize) -> Data { size == .small ? small : god }
    private static let small = encode(rows(.small))
    private static let god = encode(rows(.god))

    static func encode(_ rows: [[String: Any]], _ extra: [String: Any] = [:]) -> Data {
        var data: [String: Any] = ["me": "user_local", "rows": rows]
        data.merge(extra) { _, new in new }
        // A fixture is always valid JSON.
        return try! JSONSerialization.data(withJSONObject: ["ok": true, "data": data])
    }

    /// What a windowing host (cmux-mobile-host `InboxWindow`) sends the first screen: the first
    /// ``MacHomeRows/firstWindow`` rows of the list, `offset` 0 and the list's `total`.
    static func firstWindowWire(_ size: InstantPerfSize) -> Data { size == .small ? smallWindow : godWindow }
    private static let smallWindow = window(.small)
    private static let godWindow = window(.god)
    private static func window(_ size: InstantPerfSize) -> Data {
        encode(Array(rows(size).prefix(MacHomeRows.firstWindow)), ["offset": 0, "total": rowCount(size)])
    }

    /// The reference "now" of every fixture: 2026-11-10T00:00:00Z.
    static let now = Date(timeIntervalSince1970: 1_794_268_800)

    /// The rows in the owner's order (newest first), as `home-inbox` sends them.
    static func rows(_ size: InstantPerfSize) -> [[String: Any]] {
        let count = rowCount(size)
        var rng = SeededRandom(seed: size == .small ? 0x484F_4D45_0020 : 0x484F_4D45_5000)
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let pinned = size == .small ? 4 : 12
        let span: TimeInterval = 180 * 24 * 3600 // six months of activity
        let kinds = ["direct", "channel", "group"]
        return (0..<count).map { index in
            var row: [String: Any] = [:]
            row["id"] = "conv-\(size.rawValue)-\(index)"
            row["owner"] = "local"
            let isChief = index % 7 == 0
            row["kind"] = isChief ? "chief" : kinds[index % kinds.count]
            row["name"] = isChief ? "Chief \(index)" : "\(sentence(&rng, words: 2).capitalized) \(index)"
            row["unread"] = rng.chance(30) ? rng.int(1...40) : 0
            let at = now.addingTimeInterval(-span * Double(index) / Double(count) - Double(rng.int(0...600)))
            row["activity_at"] = stamp.string(from: at)
            // One row in ten carries a long Markdown reply (1.5-4 KB), the rest a line or two.
            let long = index % 10 == 3
            row["preview"] = markdown(&rng, bytes: long ? 1_500...4_000 : 80...400)
                .replacingOccurrences(of: "\\n", with: "\n")
            if isChief {
                row["chief"] = "agent_chief_\(index)"
                // Chiefs working: two in the small list, about eighty in the god list.
                row["chief_state"] = index % 9 == 0 ? "working" : (index % 2 == 0 ? "waiting" : "idle")
            }
            row["pinned"] = index < pinned
            if index < pinned { row["pin_position"] = 1_000 + index }
            row["marked_unread"] = index % 37 == 5
            row["muted"] = index % 23 == 4
            return row
        }
    }
}

// MARK: - Agent chat (acpmux records)

/// One chat's acpmux log, oldest first: record `i` has seq `i + 1`.
struct AgentChatLog: Sendable {
    let records: [String]
    let bytes: [Int]
    /// Indices of the prompt records (`user_message`).
    let prompts: [Int]
    /// Each turn's id and the index of its last record (`turn_result`), oldest first.
    let turnIDs: [String]
    let turnEnds: [Int]

    var count: Int { records.count }
    var totalBytes: Int { bytes.reduce(0, +) }

    /// The newest turn wholly inside the first `end` records.
    func lastTurn(before end: Int) -> String? {
        guard let index = turnEnds.lastIndex(where: { $0 < end }) else { return nil }
        return turnIDs[index]
    }

    /// The turn boundary (a record count) closest to `target`.
    func boundary(near target: Int) -> Int {
        (turnEnds.map { $0 + 1 }).min { abs($0 - target) < abs($1 - target) } ?? count
    }
}

enum AgentChatFixture {
    struct Spec {
        var records: Int
        var seed: UInt64
        /// Tool outputs larger than the usual few KB, by size; spread through the log, the last
        /// one in the newest turn.
        var bigOutputs: [Int] = []
        var images = 0
        var subagentDepth = 0
        /// A subagent chain every this many turns (0: none).
        var subagentEvery = 0
        var spanDays = 180
    }

    /// ~40 records: eight short turns with a tool call, an image and one subagent.
    static let small = generate(Spec(records: 40, seed: 0x4348_4154_0040, images: 1, subagentDepth: 1, subagentEvery: 6))
    /// A short chat a little over one open page (400 records), so a scroll up has a page to read.
    static let smallPaged = generate(Spec(records: 450, seed: 0x4348_4154_0450, images: 2))
    /// 50,000 records over six months: tool outputs up to 2 MB, subagents 5 deep, 200 images.
    static let god = generate(Spec(
        records: 50_000, seed: 0x4348_4154_C350,
        bigOutputs: [256, 512, 1_024, 256, 2_048, 512, 256, 1_024, 2_048, 512, 256, 1_024, 512, 2_048, 256, 2_048]
            .map { $0 * 1024 },
        images: 200, subagentDepth: 5, subagentEvery: 150))

    private static let base: Int64 = 1_794_268_800_000 - 180 * 86_400_000 // six months before the fixtures' now, in ms

    static func generate(_ spec: Spec) -> AgentChatLog {
        var rng = SeededRandom(seed: spec.seed)
        var records: [String] = []
        records.reserveCapacity(spec.records + 64)
        var prompts: [Int] = []
        var turnIDs: [String] = []
        var turnEnds: [Int] = []
        var bigQueue = spec.bigOutputs
        var imagesLeft = spec.images
        let span = Int64(spec.spanDays) * 86_400_000

        func at() -> Int64 { base + span * Int64(records.count) / Int64(max(spec.records, 1)) + Int64(rng.int(0...999)) }
        func push(_ dir: String, _ kind: String, _ msg: String) {
            let seq = records.count + 1
            let stamp = at()
            let line = #"{"sessionId":"s1","seq":\#(seq),"at":\#(stamp),"dir":"\#(dir)","kind":"\#(kind)","msg":\#(msg)}"#
            records.append(line)
        }
        func update(_ json: String, meta: String? = nil) -> String {
            let extra = meta.map { #","_meta":{"acpmux":\#($0)}"# } ?? ""
            return #"{"method":"session/update","params":{"sessionId":"s1","update":\#(json)\#(extra)}}"#
        }
        func chunk(_ text: String, owner: String? = nil, subagents: String? = nil) {
            var meta: [String] = []
            if let owner { meta.append(#""subagent":"\#(owner)""#) }
            if let subagents { meta.append(#""subagents":[\#(subagents)]"#) }
            let json = #"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"\#(text)"}}"#
            push("in", "agent_message_chunk", update(json, meta: meta.isEmpty ? nil : "{\(meta.joined(separator: ","))}"))
        }
        /// Planned share of the images and big outputs reached by now (they spread through the log).
        func due(_ total: Int, left: Int) -> Bool {
            guard left > 0, total > 0 else { return false }
            // The last one is kept for the tail of the log (about 60 records before the end),
            // so the first older page reads it; the open's byte cap stops short of it.
            if left == 1 { return records.count >= spec.records - 60 }
            let done = total - left
            return records.count >= spec.records * (done + 1) / (total + 1) || records.count >= spec.records - 60
        }
        func imageBlock() -> String {
            var bytes = [UInt8](repeating: 0, count: 2_400)
            for i in bytes.indices { bytes[i] = UInt8(truncatingIfNeeded: rng.next()) }
            return #"{"type":"content","content":{"type":"image","mimeType":"image/png","data":"\#(Data(bytes).base64EncodedString())"}}"#
        }
        func logText(bytes: Int) -> String {
            var out = ""
            out.reserveCapacity(bytes + 128)
            var line = 0
            while out.utf8.count < bytes {
                line += 1
                out += "2026-05-12T10:\(line % 60):\(line % 59).\(line % 997)Z INFO build[\(4000 + line % 300)]: compiling CmuxMobileKit step \(line) of 99999 ok\\n"
            }
            return out
        }
        func diffBody(bytes: Int) -> (old: String, new: String) {
            var old = "", new = ""
            old.reserveCapacity(bytes / 2 + 64)
            new.reserveCapacity(bytes / 2 + 64)
            var line = 0
            while old.utf8.count + new.utf8.count < bytes {
                line += 1
                old += "    let value\(line) = cache.read(page: \(line))\\n"
                new += "    let value\(line) = cache.read(page: \(line), bytes: 131072)\\n"
            }
            return (old, new)
        }
        func toolResult(_ id: String, kind: String = "execute", owner: String? = nil) {
            var content: [String] = []
            if owner == nil, due(spec.bigOutputs.count, left: bigQueue.count) {
                let size = bigQueue.removeFirst()
                if bigQueue.count % 2 == 0 {
                    content.append(#"{"type":"content","content":{"type":"text","text":"\#(logText(bytes: size))"}}"#)
                } else {
                    let (old, new) = diffBody(bytes: size)
                    content.append(#"{"type":"diff","path":"Sources/CmuxMobileLive/File\#(bigQueue.count).swift","oldText":"\#(old)","newText":"\#(new)"}"#)
                }
            } else if kind == "edit" {
                let (old, new) = diffBody(bytes: rng.int(300...3_000))
                content.append(#"{"type":"diff","path":"Sources/App/File\#(rng.int(1...300)).swift","oldText":"\#(old)","newText":"\#(new)"}"#)
            } else {
                content.append(#"{"type":"content","content":{"type":"text","text":"\#(logText(bytes: rng.int(200...4_000)))"}}"#)
            }
            if owner == nil, due(spec.images, left: imagesLeft) {
                imagesLeft -= 1
                content.append(imageBlock())
            }
            var meta: String?
            if let owner { meta = #"{"subagent":"\#(owner)"}"# }
            let result = #"{"sessionUpdate":"tool_call_update","toolCallId":"\#(id)","status":"completed","content":[\#(content.joined(separator: ","))],"rawOutput":{"exit_code":0}}"#
            push("in", "tool_call_update", update(result, meta: meta))
        }

        func toolCall(_ id: String, owner: String? = nil, subagents: String? = nil, closeAfter: Bool = true) {
            let kind = ["execute", "read", "edit", "search"][rng.int(0...3)]
            var meta: [String] = []
            if let owner { meta.append(#""subagent":"\#(owner)""#) }
            if let subagents { meta.append(#""subagents":[\#(subagents)]"#) }
            let call = #"{"sessionUpdate":"tool_call","toolCallId":"\#(id)","title":"\#(kind) \#(sentence(&rng, words: 3))","kind":"\#(kind)","status":"in_progress","rawInput":{"command":"swift test --filter Case\#(rng.int(1...999))"}}"#
            push("in", "tool_call", update(call, meta: meta.isEmpty ? nil : "{\(meta.joined(separator: ","))}"))
            if closeAfter { toolResult(id, kind: kind, owner: owner) }
        }
        var turn = 0
        while records.count < spec.records {
            let id = "t\(turn)"
            // The prompt; some carry recorded images (acpmux keeps their bytes).
            var images = ""
            if turn % 40 == 7, imagesLeft > 0, records.count < spec.records - 60 {
                imagesLeft -= 1
                images = #","images":[{"id":"img-\#(turn)","name":"screenshot-\#(turn).png"}]"#
            }
            prompts.append(records.count)
            push("mux", "user_message", #"{"text":"\#(sentence(&rng, words: 6...30))","promptId":"p\#(turn)","turnId":"\#(id)"\#(images)}"#)
            push("mux", "turn_started", #"{"turnId":"\#(id)"}"#)
            for _ in 0..<rng.int(1...3) { chunk(markdown(&rng, bytes: 80...600)) }
            for call in 0..<rng.int(0...3) { toolCall("tc-\(turn)-\(call)") }
            if spec.subagentEvery > 0, turn % spec.subagentEvery == spec.subagentEvery - 1 || (spec.records < 100 && turn == 1) {
                // A chain of subagents, each started by the one above it, `subagentDepth` deep.
                let chain = (0..<spec.subagentDepth).map { "sa-\(turn)-\($0)" }
                func entry(_ depth: Int, _ state: String) -> String {
                    let parent = depth == 0 ? "" : #","parent":"\#(chain[depth - 1])""#
                    return #"{"id":"\#(chain[depth])"\#(parent),"name":"Worker \#(depth)","task":"\#(sentence(&rng, words: 6))","state":"\#(state)","toolCallId":"tc-\#(turn)-sa\#(depth)"}"#
                }
                toolCall("tc-\(turn)-sa0", subagents: entry(0, "running"), closeAfter: false)
                for depth in 1..<max(chain.count, 1) {
                    toolCall("tc-\(turn)-sa\(depth)", owner: chain[depth - 1], subagents: entry(depth, "running"), closeAfter: false)
                }
                for depth in chain.indices {
                    chunk(markdown(&rng, bytes: 80...300), owner: chain[depth])
                    toolCall("tc-\(turn)-sub\(depth)", owner: chain[depth])
                }
                for depth in chain.indices.reversed() {
                    chunk("Finished.", owner: depth == 0 ? nil : chain[depth - 1], subagents: entry(depth, "completed"))
                    if depth > 0 { toolResult("tc-\(turn)-sa\(depth)", owner: chain[depth - 1]) }
                }
                toolResult("tc-\(turn)-sa0")
            }
            // The newest turn carries what is still due (the last big output, the last images).
            while records.count >= spec.records - 60, !bigQueue.isEmpty || imagesLeft > 0 {
                toolCall("tc-\(turn)-tail\(bigQueue.count)-\(imagesLeft)")
            }
            chunk(markdown(&rng, bytes: 80...400))
            push("mux", "turn_result", #"{"status":"completed","turnId":"\#(id)"}"#)
            turnIDs.append(id)
            turnEnds.append(records.count - 1)
            turn += 1
        }
        return AgentChatLog(records: records, bytes: records.map(\.utf8.count), prompts: prompts,
                            turnIDs: turnIDs, turnEnds: turnEnds)
    }
}

// MARK: - A fake acpmux over a fixture log

/// A fake Mac's acpmux serving `log`'s first `end` records, as acpmux pages them
/// (`daemon_chat_open.rs`: the newest page between `afterSeq` and `beforeSeq`, or oldest first
/// after `afterSeq` when it comes alone;
/// `limit` records, `maxBytes` of whole records with at least one). Moving `end` is the Mac
/// writing records while the phone is away. Pages are cut by index arithmetic, so the fake's
/// own cost does not grow with the log's length; only the page it sends costs.
final class InstantPerfAcpmux: @unchecked Sendable {
    let log: AgentChatLog
    private let lock = NSLock()
    private var visible: Int

    init(_ log: AgentChatLog, end: Int? = nil) {
        self.log = log
        visible = end ?? log.count
    }

    var end: Int {
        get { lock.withLock { visible } }
        set { lock.withLock { visible = newValue } }
    }

    func link() -> MockMacLink {
        MockMacLink { [self] _, data in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = object["method"] as? String else { return [] }
            let id = object["id"].map { "\($0)" } ?? "null"
            let params = object["params"] as? [String: Any] ?? [:]
            func reply(_ result: String) -> Data { Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8) }
            let end = self.end
            switch method {
            case "initialize": return [reply(#"{"protocolVersion":1}"#)]
            case "_acpmux/watch":
                return [reply(#"{"sessions":[{"sessionId":"s1","name":"Fix","harness":"codex","cwd":"/tmp/w","status":"idle"}]}"#)]
            case "_acpmux/attach":
                return [reply(#"{"session":{"sessionId":"s1","status":"idle","pending":[]},"lastSeq":\#(end),\#(page(params, end: end))}"#)]
            case "_acpmux/events":
                return [reply("{\(page(params, end: end))}")]
            default:
                return [reply("{}")]
            }
        }
    }

    private func page(_ params: [String: Any], end: Int) -> String {
        let limit = max((params["limit"] as? NSNumber)?.intValue ?? 400, 1)
        // acpmux caps a page at 1 MiB when the request names no cap (hub/paging.rs `page_bytes`).
        let maxBytes = (params["maxBytes"] as? NSNumber)?.intValue ?? 1_048_576
        var picked: [Int] = []
        var more = false
        let after = (params["afterSeq"] as? NSNumber)?.intValue
        let beforeSeq = (params["beforeSeq"] as? NSNumber)?.intValue
        if let after, beforeSeq == nil {
            // Oldest first after `after`: seq after + 1 is index `after`.
            var index = max(after, 0)
            var bytes = 0
            while index < end, picked.count < limit {
                if !picked.isEmpty, bytes + log.bytes[index] > maxBytes { break }
                bytes += log.bytes[index]
                picked.append(index)
                index += 1
            }
            more = index < end
        } else {
            // The newest records with `after < seq < before` (both optional), as acpmux reads
            // an attach with no `afterSeq` or with `beforeSeq` (server/requests.rs).
            let lower = max(after ?? 0, 0) // indices from this one
            let before = beforeSeq ?? (end + 1)
            let upper = min(before - 1, end) // indices below this
            if params["kinds"] as? [String] == ["user_message"] {
                let eligible = log.prompts.prefix(while: { $0 < upper }).filter { $0 >= lower }
                picked = Array(eligible.suffix(limit))
                more = eligible.count > picked.count
            } else {
                var index = upper - 1
                var bytes = 0
                while index >= lower, picked.count < limit {
                    if !picked.isEmpty, bytes + log.bytes[index] > maxBytes { break }
                    bytes += log.bytes[index]
                    picked.append(index)
                    index -= 1
                }
                picked.reverse()
                more = index >= lower
            }
        }
        return #""hasMore":\#(more),"events":[\#(picked.map { log.records[$0] }.joined(separator: ","))]"#
    }
}
