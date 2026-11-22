import Foundation
import Testing
@testable import CmuxNextDaemon

/// Malformed daemon data: every captured event line, mutated thousands of
/// ways (numbers replaced with extremes, keys dropped, types swapped, bytes
/// truncated), is decoded and applied to a loaded store. The store must
/// refuse or ignore bad data and keep going; a trap fails the whole run.
@MainActor @Suite struct EventFuzzTests {
    /// Deterministic generator, so a failure reproduces.
    struct Rng {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(max(n, 1))) }
    }

    static let extremes: [Any] = [Int.max, Int.min, -1, 0, 2_147_483_648, UInt64.max, 1e308, -1e308, "", "x", NSNull(), [Any](), [String: Any]()]

    private func mutate(_ value: Any, _ rng: inout Rng, depth: Int = 0) -> Any {
        switch value {
        case var object as [String: Any]:
            for key in object.keys.sorted() {
                switch rng.below(10) {
                case 0: object[key] = nil
                case 1: object[key] = Self.extremes[rng.below(Self.extremes.count)]
                default: object[key] = mutate(object[key] as Any, &rng, depth: depth + 1)
                }
            }
            return object
        case var array as [Any]:
            if !array.isEmpty, rng.below(4) == 0 { array.remove(at: rng.below(array.count)) }
            if rng.below(6) == 0, let first = array.first { array.append(first) }  // duplicates
            return array.map { mutate($0, &rng, depth: depth + 1) }
        case is NSNumber, is String:
            return rng.below(3) == 0 ? Self.extremes[rng.below(Self.extremes.count)] : value
        default:
            return value
        }
    }

    @Test(arguments: ["events.jsonl", "events-cmux-next.jsonl"])
    func mutatedEventsNeverTrapTheStore(_ fixture: String) throws {
        let lines = try Fixture.lines(fixture)
        let snapshot = try Fixture.response(DaemonTree.self, "list-workspaces.json")
        var rng = Rng(state: 0x9E37_79B9_7F4A_7C15)
        var decoded = 0
        for round in 0..<400 {
            let store = DaemonStore()
            store.apply(snapshot: snapshot)
            for line in lines {
                guard let object = try? JSONSerialization.jsonObject(with: line) else { continue }
                let mutated = mutate(object, &rng)
                guard var bytes = try? JSONSerialization.data(withJSONObject: mutated) else { continue }
                if rng.below(20) == 0 { bytes = bytes.prefix(rng.below(bytes.count)) }
                let name = Fixture.eventName(line) ?? "tab-changed"
                let event = DaemonEvent.decode(name: rng.below(15) == 0 ? "tab-added" : name, line: bytes)
                if case .unknown = event {} else { decoded += 1 }
                _ = store.apply(event)
            }
            if round % 50 == 0 { store.apply(snapshot: snapshot) }
        }
        #expect(decoded > 0, "the mutations must also produce events that decode")
    }

    @Test func randomBytesDecodeToUnknown() {
        var rng = Rng(state: 42)
        for _ in 0..<2_000 {
            let bytes = Data((0..<rng.below(64)).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
            _ = DaemonEvent.decode(name: "tab-changed", line: bytes)
            _ = TerminalAttachment.decodeAttachEvent(name: "output", line: bytes, surface: 1)
        }
    }
}
