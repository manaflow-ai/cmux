import Foundation
import Testing
@testable import CmuxNextAgentPane

/// ad349, round 7: Foundation keeps one of two duplicate keys without an error, and the daemon's
/// serde_json keeps the last, so a duplicate could be checked as one value and acted on as the other.
/// The relay refuses any frame in which one object holds two keys that decode to equal strings (also
/// canonically equal ones, which Swift's String treats as one key), before it parses the frame.
@MainActor
@Suite(.serialized) struct AgentPaneDuplicateKeyTests {
    typealias Rig = AgentPaneProductRulesTests.Rig

    func refuses(_ text: String) -> Bool { AcpmuxJSONKeys.refuses(Array(text.utf8)) }

    @Test func aDuplicateCwdIsRefused() async throws {
        let rig = Rig()
        try await rig.start()
        defer { rig.server.stop() }
        let root = rig.root
        rig.transport.roots = { [root] }
        let frames = [
            #"{"jsonrpc":"2.0","id":5,"method":"session/new","params":{"cwd":"\#(root)","cwd":"/etc","mcpServers":[]}}"#,
            #"{"jsonrpc":"2.0","id":6,"method":"session/new","params":{"cwd":"\#(root)","cwd":"/etc","mcpServers":[]}}"#,
            #"{"jsonrpc":"2.0","id":7,"method":"session/new","params":{"cwd":"/etc","cwd":"\#(root)","mcpServers":[]}}"#,
            #"{"jsonrpc":"2.0","id":8,"method":"session/new","params":{"cwd":"\#(root)","mcpServers":[],"_meta":{"acpmux":{"harness":"claude"},"acpmux":{"harness":"claude","permissionMode":"bypassPermissions"}}}}"#,
            #"{"jsonrpc":"2.0","id":9,"method":"session/new","params":{"cwd":"\#(root)","mcpServers":[],"_meta":{"acpmux":{"harness":"claude","harness":"codex"}}}}"#,
            #"{"jsonrpc":"2.0","id":10,"id":11,"method":"session/new","params":{"cwd":"\#(root)","mcpServers":[]}}"#,
        ]
        for frame in frames {
            #expect(await rig.transport.send(connection: rig.connection, frames: [frame]) == .duplicateKey, "\(frame)")
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(rig.server.peers.first?.frames.contains { $0.contains("session/new") || $0.contains("session\\/new") } == false)
        // The same frame without the duplicate passes, as a fresh serialization.
        #expect(await rig.transport.send(connection: rig.connection, frames: [
            #"{"jsonrpc":"2.0","id":12,"method":"session/new","params":{"cwd":"\#(root)","mcpServers":[]}}"#]) == nil)
    }

    @Test func hostileFrames() {
        // Escaped keys that decode to one string, at the top and deep down.
        #expect(refuses(#"{"a":1,"a":2}"#))
        #expect(refuses(#"{"x":[{"k":{"\/":1,"/":2}}]}"#))
        #expect(refuses(#"{"😀":1,"😀":2}"#))
        #expect(refuses(#"{"\n":1,"\u000a":2}"#))
        // Canonically equal keys (é composed and decomposed): one key to Swift.
        #expect(refuses(#"{"é":1,"é":2}"#))
        // Not duplicates: other objects, other case, a value equal to a key.
        #expect(!refuses(#"{"a":{"a":1},"b":[{"a":1},{"a":2}],"A":"a"}"#))
        #expect(!refuses(#"{"cwd":"cwd","c":"cwd"}"#))
        // Not well-formed: refused.
        for bad in [#"{"a":1"#, #"{"a" 1}"#, #"{"a":1,}"#, #"{"\ud800":1}"#, #"{"a":"\x"}"#, "{\"a\":\"tab\u{09}x\"}", "{\"a\":1}}", "", "{"] {
            #expect(refuses(bad), "\(bad.debugDescription)")
        }
        #expect(AcpmuxJSONKeys.refuses([0x7B, 0x22, 0xC3, 0x28, 0x22, 0x3A, 0x31, 0x7D]), "invalid UTF-8 in a key")
        #expect(AcpmuxJSONKeys.refuses(Array(#"{"a":""#.utf8) + [0xFF] + Array(#""}"#.utf8)), "invalid UTF-8 in a value")
        // Deep nesting and huge strings.
        let deep = String(repeating: #"{"a":["#, count: 20_000) + "1" + String(repeating: "]}", count: 20_000)
        #expect(!refuses(deep))
        let deepDuplicate = String(repeating: #"{"a":["#, count: 20_000) + #"{"k":1,"k":2}"# + String(repeating: "]}", count: 20_000)
        #expect(refuses(deepDuplicate))
        let huge = String(repeating: "x", count: 5_000_000)
        #expect(!refuses(#"{"a":"\#(huge)","b":"\#(huge)"}"#))
        #expect(refuses(#"{"\#(huge)":1,"\#(huge)":2}"#))
    }

    // MARK: Fuzz, against the full parser

    /// SplitMix64, seeded, so a failure reproduces.
    struct Random {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
        mutating func chance(_ percent: Int) -> Bool { below(100) < percent }
    }

    /// Key and string parts: ASCII, quotes, backslashes, controls, accents (composed and not),
    /// a non-BMP emoji.
    static let pieces = ["a", "b", "cwd", "mode", "\"", "\\", "/", "\n", "\u{01}", "é", "e\u{0301}", "😀", " ", "_meta", "ä"]

    /// One JSON string for `text`, with each character written plainly or escaped at random.
    static func encode(_ text: String, _ random: inout Random) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            let mustEscape = scalar == "\"" || scalar == "\\" || scalar.value < 0x20
            if mustEscape || random.chance(30) {
                switch (scalar, random.below(2)) {
                case ("\"", 0): out += "\\\""
                case ("\\", 0): out += "\\\\"
                case ("/", 0): out += "\\/"
                case ("\n", 0): out += "\\n"
                default:
                    for unit in String(scalar).utf16 { out += String(format: "\\u%04x", unit) }
                }
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// A random JSON value; `duplicated` is set when some object got a key twice (by Swift equality).
    static func value(_ depth: Int, _ random: inout Random, _ duplicated: inout Bool, plant: Bool) -> String {
        switch depth > 4 ? random.below(4) : random.below(6) {
        case 0: return String(random.below(1000) - 500)
        case 1: return ["true", "false", "null", "1.5e3"][random.below(4)]
        case 2, 3:
            let text = (0..<random.below(4)).map { _ in pieces[random.below(pieces.count)] }.joined()
            return encode(text, &random)
        case 4:
            return "[" + (0..<random.below(4)).map { _ in value(depth + 1, &random, &duplicated, plant: plant) }.joined(separator: ",") + "]"
        default:
            var keys: [String] = []
            for _ in 0..<random.below(5) {
                let key = (0..<(1 + random.below(3))).map { _ in pieces[random.below(pieces.count)] }.joined()
                if !keys.contains(key) { keys.append(key) }
            }
            if plant, !keys.isEmpty, random.chance(60) {
                keys.insert(keys[random.below(keys.count)], at: random.below(keys.count + 1))
                duplicated = true
            }
            let members = keys.map { encode($0, &random) + ":" + value(depth + 1, &random, &duplicated, plant: plant) }
            return "{" + members.joined(separator: ",") + "}"
        }
    }

    @Test func theCheckAgreesWithTheFullParserOnRandomFrames() {
        var random = Random(state: 0xC0FFEE)
        var planted = 0
        var clean = 0
        for round in 0..<4000 {
            var duplicated = false
            // params is always an object, so a planted round has at least one object to plant in.
            let plant = round % 2 == 0
            let params = "{" + Self.encode("p", &random) + ":" + Self.value(0, &random, &duplicated, plant: plant) + ","
                + Self.encode("q", &random) + ":" + Self.value(1, &random, &duplicated, plant: plant) + "}"
            let text = #"{"jsonrpc":"2.0","id":\#(round),"params":"# + params + "}"
            if duplicated {
                planted += 1
                #expect(refuses(text), "missed a duplicate: \(text)")
            } else {
                clean += 1
                #expect(!refuses(text), "refused a clean frame: \(text)")
                // A clean frame is one the full parser reads.
                #expect((try? JSONSerialization.jsonObject(with: Data(text.utf8))) != nil, "not JSON: \(text)")
            }
        }
        #expect(planted > 200 && clean > 1500, "planted \(planted), clean \(clean)")
        // Random byte damage: whatever the check lets through, the full parser must read.
        for _ in 0..<4000 {
            var duplicated = false
            var bytes = Array((#"{"p":"# + Self.value(0, &random, &duplicated, plant: false) + "}").utf8)
            for _ in 0..<(1 + random.below(3)) where !bytes.isEmpty {
                let at = random.below(bytes.count)
                switch random.below(3) {
                case 0: bytes[at] = UInt8(truncatingIfNeeded: random.next())
                case 1: bytes.remove(at: at)
                default: bytes.insert(Array(#"{}[]",:\"#.utf8)[random.below(8)], at: at)
                }
            }
            if !AcpmuxJSONKeys.refuses(bytes) {
                #expect((try? JSONSerialization.jsonObject(with: Data(bytes), options: [.fragmentsAllowed])) != nil,
                        "accepted bytes the full parser refuses: \(String(decoding: bytes, as: UTF8.self))")
            }
        }
    }
}
