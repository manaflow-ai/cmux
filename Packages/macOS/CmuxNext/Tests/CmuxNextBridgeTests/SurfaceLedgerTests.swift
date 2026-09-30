import Testing
@testable import CmuxNextBridge

/// The surface lifecycle during tab moves: a surface is keyed by tab, the
/// latest presenter owns it, and stale presenters cannot pause or evict it.
struct SurfaceLedgerTests {
    typealias Ledger = SurfaceLedger<String, String>

    @Test func moveToAnotherPaneKeepsTheSurfaceRenderingWhateverTheOrder() {
        // Destination presents first, then the stale source withdraws.
        var ledger = Ledger()
        _ = ledger.present("t", by: "A", ownerVisible: true)
        let take = ledger.present("t", by: "B", ownerVisible: true)
        #expect(take.displaced == [.init(key: "t", owner: "A")])
        #expect(take.rendering.isEmpty && take.evicted.isEmpty)
        #expect(ledger.withdraw("t", by: "A").isEmpty)
        #expect(ledger.removeOwner("A").isEmpty)
        #expect(ledger.owner(of: "t") == "B")
        #expect(ledger.isRendering("t"))

        // Source withdraws first, then the destination presents.
        var other = Ledger()
        _ = other.present("t", by: "A", ownerVisible: true)
        #expect(other.withdraw("t", by: "A").rendering == ["t": false])
        #expect(other.present("t", by: "B", ownerVisible: true).rendering == ["t": true])
        #expect(other.isRendering("t"))
    }

    @Test func aStaleSourceHidingNeverEvictsTheMovedSurface() {
        var ledger = Ledger(capacity: 1)
        _ = ledger.present("t", by: "A", ownerVisible: true)
        _ = ledger.present("t", by: "B", ownerVisible: true)
        // Source scrolls away and its other tabs churn through the LRU.
        _ = ledger.setVisible(false, owner: "A")
        for key in ["x", "y", "z"] {
            _ = ledger.present(key, by: "A", ownerVisible: false)
            _ = ledger.withdraw(key, by: "A")
        }
        #expect(ledger.owner(of: "t") == "B")
        #expect(ledger.isRendering("t"))
        #expect(ledger.isRetained("t"))
    }

    @Test func offscreenPresenterIsToldWhenItsSurfaceIsEvicted() {
        var ledger = Ledger(capacity: 1)
        _ = ledger.present("a", by: "P", ownerVisible: true)
        #expect(ledger.setVisible(false, owner: "P").rendering == ["a": false])
        _ = ledger.present("b", by: "Q", ownerVisible: true)
        let effects = ledger.withdraw("b", by: "Q")
        #expect(effects.evicted == ["a"])
        #expect(effects.displaced == [.init(key: "a", owner: "P")])
        #expect(ledger.owner(of: "a") == nil)
        // Scrolling back re-presents; nothing is rendering until then.
        #expect(ledger.setVisible(true, owner: "P").isEmpty)
        #expect(ledger.present("a", by: "P", ownerVisible: true).rendering == ["a": true])
    }

    @Test func visibilityFollowsTheOwnerNotTheKey() {
        var ledger = Ledger()
        _ = ledger.present("t", by: "A", ownerVisible: false)
        #expect(!ledger.isRendering("t"))
        #expect(ledger.setVisible(true, owner: "A").rendering == ["t": true])
        // A stale pane's visibility change touches only what it owns.
        #expect(ledger.setVisible(false, owner: "B").isEmpty)
        #expect(ledger.isRendering("t"))
    }

    @Test func removeForgetsTheKeyAndReportsItsPresenter() {
        var ledger = Ledger()
        _ = ledger.present("t", by: "A", ownerVisible: true)
        #expect(ledger.remove("t") == "A")
        #expect(!ledger.isRendering("t") && !ledger.isRetained("t"))
        #expect(ledger.withdraw("t", by: "A").isEmpty)
    }

    /// 200 random presents, withdraws, visibility flips and pane teardowns:
    /// the ledger never renders a key without a visible owner, and a key
    /// with a visible owner always renders and is never evicted.
    @Test func randomOperationsKeepPresentedVisibleKeysAlive() {
        var generator = SplitMix(seed: 7)
        var ledger = Ledger(capacity: 2)
        let keys = ["a", "b", "c", "d", "e", "f"], owners = ["P", "Q", "R"]
        var visible: [String: Bool] = [:]
        for _ in 0 ..< 200 {
            let key = keys[Int(generator.next() % 6)], owner = owners[Int(generator.next() % 3)]
            let effects: Ledger.Effects
            switch generator.next() % 4 {
            case 0:
                let isVisible = generator.next() % 2 == 0
                visible[owner] = isVisible
                effects = ledger.present(key, by: owner, ownerVisible: isVisible)
            case 1: effects = ledger.withdraw(key, by: owner)
            case 2:
                let isVisible = generator.next() % 2 == 0
                visible[owner] = isVisible
                effects = ledger.setVisible(isVisible, owner: owner)
            default:
                visible[owner] = nil
                effects = ledger.removeOwner(owner)
            }
            for evicted in effects.evicted {
                let owner = ledger.owner(of: evicted)
                #expect(owner == nil || visible[owner!] != true)
            }
            for key in keys {
                let shouldRender = ledger.owner(of: key).map { visible[$0] == true } ?? false
                #expect(ledger.isRendering(key) == shouldRender)
            }
        }
    }
}

private struct SplitMix {
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

/// Off-screen columns within one viewport width keep their surfaces, paused
/// (architecture.md 4), so a scroll back shows content with no re-attach.
struct SurfaceLedgerKeepAliveTests {
    typealias Ledger = SurfaceLedger<String, String>

    @Test func keepAliveOwnersArePausedButNeverEvicted() {
        var ledger = Ledger(capacity: 1)
        _ = ledger.present("near", by: "N", presence: .visible)
        let scrolled = ledger.setPresence(.keepAlive, owner: "N")
        #expect(scrolled.rendering == ["near": false])
        #expect(scrolled.evicted.isEmpty)
        // Many hidden tabs churn through a 1-slot LRU.
        for key in ["x", "y", "z", "w"] {
            let effects = ledger.present(key, by: "H\(key)", presence: .hidden)
            #expect(!effects.evicted.contains("near"))
        }
        #expect(ledger.isRetained("near"))
        #expect(ledger.owner(of: "near") == "N")
        #expect(ledger.setPresence(.visible, owner: "N").rendering == ["near": true])
    }

    @Test func leavingTheBandReturnsTheSurfaceToTheLRU() {
        var ledger = Ledger(capacity: 1)
        _ = ledger.present("far", by: "F", presence: .keepAlive)
        _ = ledger.present("other", by: "O", presence: .hidden)
        #expect(ledger.isRetained("far"))
        let left = ledger.setPresence(.hidden, owner: "F")
        // "other" was hidden first, so it is the one the 1-slot LRU drops.
        #expect(left.evicted == ["other"])
        let churn = ledger.present("third", by: "T", presence: .hidden)
        #expect(churn.evicted == ["far"])
        #expect(churn.displaced == [.init(key: "far", owner: "F")])
    }

    @Test func randomPresenceChangesNeverEvictAKeepAliveOrVisibleKey() {
        var generator = SeededGenerator(seed: 7)
        var ledger = Ledger(capacity: 2)
        let owners = ["A", "B", "C", "D", "E"]
        var presence: [String: SurfacePresence] = [:]
        var shown: [String: String] = [:]
        for step in 0..<400 {
            let owner = owners.randomElement(using: &generator)!
            if Bool.random(using: &generator) {
                let next: SurfacePresence = [.visible, .keepAlive, .hidden].randomElement(using: &generator)!
                presence[owner] = next
                _ = ledger.setPresence(next, owner: owner)
            } else {
                let key = "k\(Int.random(in: 0..<8, using: &generator))"
                shown = shown.filter { $0.value != key }
                shown[owner] = key
                _ = ledger.present(key, by: owner, presence: presence[owner] ?? .hidden)
            }
            for (owner, key) in shown where ledger.owner(of: key) == owner {
                let state = presence[owner] ?? .hidden
                #expect(ledger.isRendering(key) == (state == .visible), "step \(step)")
                if state != .hidden { #expect(ledger.isRetained(key), "step \(step)") }
            }
        }
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state >> 11 | state << 53
    }
}

/// Browser pages stay out of the terminal warm set, and the warm set
/// shrinks under memory pressure.
struct SurfaceLedgerWarmSetTests {
    typealias Ledger = SurfaceLedger<String, String>

    @Test func unretainedKeysNeitherCountNorGetEvicted() {
        var ledger = Ledger(capacity: 2)
        ledger.setRetained("page1", false)
        ledger.setRetained("page2", false)
        var evicted: [String] = []
        for key in ["t1", "page1", "t2", "page2", "t3"] {
            evicted += ledger.present(key, by: "P", ownerVisible: true).evicted
            evicted += ledger.withdraw(key, by: "P").evicted
        }
        // Three terminals through a warm set of two: only the oldest goes.
        #expect(evicted == ["t1"])
    }

    @Test func shrinkingTheCapacityEvictsTheOldestHiddenSurfaces() {
        var ledger = Ledger(capacity: 4)
        for key in ["a", "b", "c", "d"] {
            _ = ledger.present(key, by: "P", ownerVisible: true)
            _ = ledger.withdraw(key, by: "P")
        }
        let effects = ledger.setCapacity(1)
        #expect(effects.evicted == ["a", "b", "c"])
        #expect(ledger.isRetained("d"))
        #expect(ledger.capacity == 1)
    }
}

/// The warm set follows physical memory and memory pressure.
struct WarmSetBudgetTests {
    @Test func sizesFromMemoryAndShrinksUnderPressure() {
        let gb: UInt64 = 1 << 30
        #expect(WarmSetBudget.forMemory(physicalBytes: 8 * gb, pressure: .normal) == WarmSetBudget(terminalCapacity: 4, parkedWorkspaces: 8, parkedPanes: 4))
        #expect(WarmSetBudget.forMemory(physicalBytes: 64 * gb, pressure: .normal) == WarmSetBudget(terminalCapacity: 10, parkedWorkspaces: 8, parkedPanes: 10))
        #expect(WarmSetBudget.forMemory(physicalBytes: 256 * gb, pressure: .normal).terminalCapacity == 12)
        #expect(WarmSetBudget.forMemory(physicalBytes: 256 * gb, pressure: .warning) == WarmSetBudget(terminalCapacity: 4, parkedWorkspaces: 1, parkedPanes: 2))
        #expect(WarmSetBudget.forMemory(physicalBytes: 256 * gb, pressure: .critical) == WarmSetBudget(terminalCapacity: 0, parkedWorkspaces: 0, parkedPanes: 0))
    }
}
