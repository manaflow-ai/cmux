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
