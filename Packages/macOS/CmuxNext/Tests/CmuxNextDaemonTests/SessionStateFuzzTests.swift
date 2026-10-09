import Foundation
import Testing
@testable import CmuxNextDaemon

/// Malformed state stream items (crash program phase 3): numbers the daemon
/// sends in `session.events` state resources reach Int conversions. Any value
/// must decode, saturate or be ignored; a trap fails the run.
@MainActor @Suite struct SessionStateFuzzTests {
    struct Rng {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(max(n, 1))) }
    }

    static let extremes: [Any] = [Int.max, Int.min, -1, 0, UInt64.max, 1e308, -1e308, 0.5, "", NSNull(), [Any](), [String: Any]()]

    private func loadedStore() throws -> DaemonStore {
        let store = DaemonStore()
        store.apply(snapshot: try Fixture.response(DaemonTree.self, "list-workspaces.json"))
        return store
    }

    private func apply(_ line: Data, to store: DaemonStore) {
        let event = DaemonEvent.decode(name: LineTransport.streamEvent, line: line)
        store.apply(batch: [DaemonEventEnvelope(sequence: 1, event: event)])
    }

    /// A terminal progress value past Int's range used to trap in Int(_:).
    @Test func terminalProgressPastIntRangeSaturates() throws {
        for (value, expected) in [("1e308", Int.max), ("-1e308", Int.min), ("9223372036854775808", Int.max), ("40.9", 40)] {
            let line = SessionStateTests.snapshot.replacingOccurrences(of: #""value":40"#, with: #""value":\#(value)"#)
            let store = try loadedStore()
            apply(Data(line.utf8), to: store)
            let tab = try #require(store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs)
                .first { $0.resourceID?.rawValue == SessionStateTests.tab })
            #expect(tab.progress?.value == expected)
        }
    }

    @Test func mutatedStateSnapshotsNeverTrapTheStore() throws {
        let base = try #require(try JSONSerialization.jsonObject(with: Data(SessionStateTests.snapshot.utf8)) as? [String: Any])
        var rng = Rng(state: 0x5EED_57A7)
        func mutate(_ value: Any, depth: Int) -> Any {
            switch value {
            case var object as [String: Any]:
                for key in object.keys.sorted() where rng.below(4) == 0 || depth < 4 {
                    object[key] = rng.below(8) == 0
                        ? Self.extremes[rng.below(Self.extremes.count)]
                        : mutate(object[key] as Any, depth: depth + 1)
                }
                return object
            case let array as [Any]:
                return array.map { mutate($0, depth: depth + 1) }
            case is NSNumber, is String:
                return rng.below(3) == 0 ? Self.extremes[rng.below(Self.extremes.count)] : value
            default:
                return value
            }
        }
        for _ in 0..<300 {
            guard let bytes = try? JSONSerialization.data(withJSONObject: mutate(base, depth: 0)) else { continue }
            apply(bytes, to: try loadedStore())
        }
    }
}
