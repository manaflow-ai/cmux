#if canImport(UIKit)
import Testing

@testable import CmuxMobileTerminal

@MainActor
@Suite("Ghostty surface free retention")
struct GhosttySurfaceFreeRetentionTests {
    /// Exercises the post-free retention boundary with a non-UIKit probe.
    @Test("retention keeps the view alive through a fake free and releases once")
    func retentionKeepsViewAliveThroughFakeFree() {
        var probe: LifetimeProbe? = LifetimeProbe()
        weak var weakProbe = probe
        let retention = GhosttySurfaceFreeRetention(object: probe!)
        probe = nil

        #expect(weakProbe != nil)

        // This test-only callback stands in for the serial queue's
        // `ghostty_surface_free` call. It must run while the raw view pointer
        // is still backed by a live object.
        var fakeFree = FakeSurfaceFree()
        fakeFree.run { #expect(weakProbe != nil) }
        #expect(fakeFree.callCount == 1)
        #expect(weakProbe != nil)

        #expect(retention.releaseAfterSurfaceFree())
        #expect(!retention.releaseAfterSurfaceFree())
        #expect(weakProbe == nil)
    }

    /// Repeats the fake free protocol to expose leaked or duplicate releases.
    @Test("repeated free cycles do not accumulate retention or double release")
    func repeatedFreeCyclesRemainBounded() {
        for _ in 0..<128 {
            var probe: LifetimeProbe? = LifetimeProbe()
            weak var weakProbe = probe
            let retention = GhosttySurfaceFreeRetention(object: probe!)
            probe = nil

            #expect(weakProbe != nil)
            #expect(retention.releaseAfterSurfaceFree())
            #expect(!retention.releaseAfterSurfaceFree())
            #expect(weakProbe == nil)
        }
    }
}

private final class LifetimeProbe {}

private struct FakeSurfaceFree {
    private(set) var callCount = 0

    /// Invokes the fake free callback exactly once for this test operation.
    mutating func run(_ callback: () -> Void) {
        callCount += 1
        callback()
    }
}

#endif
