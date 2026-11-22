import CmuxNextHistory
import Foundation
import Testing

/// Back / Forward scope (plans/cmux-next/history.md 4.2a, R69): `workspace` and `window` filter the
/// one trail; entries out of scope are kept and never returned; `surface` walks no trail entry.
struct LocationTrailScopeTests {
    static func loc(_ tab: String, workspace: String, window: String = "w1", machine: String = "home") -> HistoryLocation {
        HistoryLocation(key: .init(machine: machine, tab: tab), window: window, workspace: workspace, pane: "p-\(tab)",
                        content: .terminal, title: tab.uppercased())
    }

    static let t0 = Date(timeIntervalSince1970: 1_000_000)

    static func trail(_ locations: [HistoryLocation]) -> LocationTrail {
        var trail = LocationTrail()
        for (index, location) in locations.enumerated() { trail.record(location, at: t0.addingTimeInterval(Double(index) * 2)) }
        return trail
    }

    @Test func workspaceScopeWalksOnlyTheCurrentWorkspace() {
        var trail = Self.trail([Self.loc("a", workspace: "A"), Self.loc("x", workspace: "X"), Self.loc("b", workspace: "A"),
                                Self.loc("c", workspace: "A")])
        let back = trail.back(scope: .workspace)
        #expect(back?.location.key.tab == "b")
        trail.record(Self.loc("b", workspace: "A"), at: Self.t0.addingTimeInterval(100))
        #expect(trail.back(scope: .workspace)?.location.key.tab == "a", "x is in another workspace")
        #expect(trail.entries.map(\.location.key.tab) == ["a", "x", "b", "c"], "out-of-scope entries stay")
    }

    @Test func sameWorkspaceKeyOnAnotherMachineIsAnotherWorkspace() {
        var trail = Self.trail([Self.loc("a", workspace: "A", machine: "mini"), Self.loc("b", workspace: "A")])
        #expect(trail.back(scope: .workspace) == nil)
        #expect(!trail.canGoBack(scope: .workspace))
        #expect(trail.canGoBack(scope: .window))
    }

    @Test func windowScopeWalksTheCurrentWindowAcrossWorkspaces() {
        var trail = Self.trail([Self.loc("a", workspace: "A", window: "w1"), Self.loc("o", workspace: "O", window: "w2"),
                                Self.loc("x", workspace: "X", window: "w1")])
        #expect(trail.back(scope: .window)?.location.key.tab == "a")
    }

    @Test func surfaceScopeWalksNoTrailEntry() {
        var trail = Self.trail([Self.loc("a", workspace: "A"), Self.loc("b", workspace: "A")])
        #expect(trail.back(scope: .surface) == nil)
        #expect(trail.forward(scope: .surface) == nil)
        #expect(trail.cursor == 1)
    }

    @Test func forwardAndLastRespectTheScope() {
        var trail = Self.trail([Self.loc("a", workspace: "A"), Self.loc("x", workspace: "X"), Self.loc("b", workspace: "A")])
        _ = trail.back(scope: .workspace)
        trail.record(Self.loc("a", workspace: "A"), at: Self.t0.addingTimeInterval(100))
        #expect(trail.canGoForward(scope: .workspace))
        #expect(trail.forward(scope: .workspace)?.location.key.tab == "b")
    }

    @Test func theListShowsInScopeEntriesNearestFirst() {
        let trail = Self.trail([Self.loc("a", workspace: "A"), Self.loc("x", workspace: "X"), Self.loc("b", workspace: "A"),
                                Self.loc("c", workspace: "A")])
        #expect(trail.list(.back, scope: .workspace).map(\.entry.location.key.tab) == ["b", "a"])
        #expect(trail.list(.back, scope: .window).map(\.entry.location.key.tab) == ["b", "x", "a"])
        #expect(trail.list(.forward, scope: .workspace).isEmpty)
        #expect(trail.list(.back, scope: .surface).isEmpty)
    }

    @Test func goingToAListedEntryMovesTheCursorThere() {
        var trail = Self.trail([Self.loc("a", workspace: "A"), Self.loc("b", workspace: "A"), Self.loc("c", workspace: "A")])
        let target = trail.list(.back, scope: .workspace)[1]
        #expect(trail.go(to: target.index)?.location.key.tab == "a")
        #expect(trail.cursor == 0)
        #expect(trail.pending == Self.loc("a", workspace: "A").key)
        #expect(trail.go(to: 99) == nil)
    }

    /// Seeded property test: over random trails and moves, a scoped move never returns an entry out of
    /// scope, and moves never change the entries.
    @Test func scopedMovesNeverLeaveTheScopeOrDropEntries() {
        var generator = SplitMix(seed: 0x5EED)
        for _ in 0..<200 {
            var locations: [HistoryLocation] = []
            for index in 0..<Int(generator.next() % 12 + 1) {
                let workspace = ["A", "B", "C"][Int(generator.next() % 3)]
                let window = ["w1", "w2"][Int(generator.next() % 2)]
                locations.append(Self.loc("t\(index)", workspace: workspace, window: window))
            }
            var trail = Self.trail(locations)
            let entries = trail.entries
            for _ in 0..<8 {
                let scope = HistoryScope.allCases[Int(generator.next() % 3)]
                guard let current = trail.current?.location else { break }
                let moved = generator.next() % 2 == 0 ? trail.back(scope: scope) : trail.forward(scope: scope)
                if let moved {
                    #expect(HistoryScope.contains(moved.location, current: current, scope: scope))
                }
                #expect(trail.entries == entries)
            }
        }
    }
}

/// A small deterministic generator for the seeded property test.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
