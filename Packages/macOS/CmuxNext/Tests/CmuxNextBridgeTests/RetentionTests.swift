import CoreGraphics
import Testing
@testable import CmuxNextBridge

struct SurfaceRetentionTests {
    @Test func hiddenSurfacesBeyondCapacityAreEvictedOldestFirst() {
        var retention = SurfaceRetention<String>(capacity: 2)
        for key in ["a", "b", "c"] { retention.setVisible(key, true) }
        #expect(retention.setVisible("a", false).isEmpty)
        #expect(retention.setVisible("b", false).isEmpty)
        #expect(retention.setVisible("c", false) == ["a"])
        #expect(!retention.isRetained("a"))
        #expect(retention.isRetained("b") && retention.isRetained("c"))
    }

    @Test func showingARetainedSurfaceTakesItOutOfTheLRU() {
        var retention = SurfaceRetention<String>(capacity: 1)
        retention.setVisible("a", true)
        retention.setVisible("a", false)
        retention.setVisible("a", true)
        #expect(retention.recent.isEmpty)
        #expect(retention.visible == ["a"])
    }
}

struct ResizeSettleTests {
    @Test func sizeIsReleasedOnlyAfterItStopsChanging() {
        var settle = ResizeSettle<String, Int>(stableFrames: 2)
        settle.submit("t", size: 80)
        #expect(settle.tick().isEmpty)
        settle.submit("t", size: 90) // still animating
        #expect(settle.tick().isEmpty)
        let ready = settle.tick()
        #expect(ready.count == 1 && ready[0].size == 90)
        #expect(settle.isIdle)
    }

    @Test func heldKeysWaitForRelease() {
        var settle = ResizeSettle<String, Int>(stableFrames: 1)
        settle.submit("t", size: 80)
        #expect(settle.tick(held: ["t"]).isEmpty)
        #expect(settle.tick().first?.size == 80)
    }
}

struct PreviewImageCacheTests {
    static func image(_ side: Int) -> CGImage {
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }

    @Test func evictsLeastRecentlyUsedToStayUnderTheCap() {
        let cache = PreviewImageCache(capacityBytes: 3 * 100 * 100 * 4)
        cache.insert(Self.image(100), for: "a")
        cache.insert(Self.image(100), for: "b")
        cache.insert(Self.image(100), for: "c")
        _ = cache.image(for: "a")
        cache.insert(Self.image(100), for: "d")
        #expect(cache.image(for: "b") == nil)
        #expect(cache.image(for: "a") != nil)
        #expect(cache.totalBytes <= cache.capacityBytes)
    }
}

struct TabSelectionMemoryTests {
    @Test func closingTheSelectedTabSelectsItsRightNeighbor() {
        var memory = TabSelectionMemory()
        #expect(memory.resolve(pane: "p", tabs: ["a", "b", "c"], defaultIndex: 0) == "a")
        memory.select("b", in: "p")
        _ = memory.resolve(pane: "p", tabs: ["a", "b", "c"], defaultIndex: 0)
        #expect(memory.resolve(pane: "p", tabs: ["a", "c"], defaultIndex: 0) == "c")
        #expect(memory.resolve(pane: "p", tabs: ["a"], defaultIndex: 0) == "a")
    }

    // close-focus.md: a collapsed group's members are skipped while a shown tab survives.
    @Test func closingTheSelectedTabSkipsCollapsedGroupMembers() {
        var memory = TabSelectionMemory()
        memory.select("b", in: "p")
        _ = memory.resolve(pane: "p", tabs: ["a", "b", "g1", "g2", "c"], defaultIndex: 0, hidden: ["g1", "g2"])
        #expect(memory.resolve(pane: "p", tabs: ["a", "g1", "g2", "c"], defaultIndex: 0, hidden: ["g1", "g2"]) == "c")
        memory.select("c", in: "p")
        _ = memory.resolve(pane: "p", tabs: ["a", "g1", "g2", "c"], defaultIndex: 0, hidden: ["g1", "g2"])
        #expect(memory.resolve(pane: "p", tabs: ["a", "g1", "g2"], defaultIndex: 0, hidden: ["g1", "g2"]) == "a")
    }

    @Test func onlyHiddenTabsLeftSelectsTheNeighborAnyway() {
        var memory = TabSelectionMemory()
        memory.select("a", in: "p")
        _ = memory.resolve(pane: "p", tabs: ["a", "g1", "g2"], defaultIndex: 0, hidden: ["g1", "g2"])
        #expect(memory.resolve(pane: "p", tabs: ["g1", "g2"], defaultIndex: 0, hidden: ["g1", "g2"]) == "g1")
    }

    @Test func unknownPaneUsesTheDaemonDefault() {
        var memory = TabSelectionMemory()
        #expect(memory.resolve(pane: "p", tabs: ["a", "b"], defaultIndex: 1) == "b")
    }
}
