#if canImport(UIKit)
import Testing

@testable import CmuxMobileTerminal

@MainActor
@Suite("Ghostty surface free retention")
struct GhosttySurfaceFreeRetentionTests {
    @Test("retention keeps the view alive through a fake free and releases once")
    func retentionKeepsViewAliveThroughFakeFree() {
        var callbackCount = 0
        var probe: LifetimeProbe? = LifetimeProbe()
        weak var weakProbe = probe
        let retention = GhosttySurfaceFreeRetention(
            object: probe!,
            onRelease: {
                callbackCount += 1
                // The callback is the post-free boundary; the UIKit object is
                // still alive until the token drops its final strong retain.
                #expect(weakProbe != nil)
            }
        )
        probe = nil

        #expect(weakProbe != nil)

        // This closure stands in for the serial queue's
        // `ghostty_surface_free` call. It must run while the raw view pointer
        // is still backed by a live object.
        var fakeFreeCount = 0
        fakeFreeCount += 1
        #expect(weakProbe != nil)
        #expect(fakeFreeCount == 1)

        #expect(retention.releaseAfterSurfaceFree())
        #expect(!retention.releaseAfterSurfaceFree())
        #expect(callbackCount == 1)
        #expect(weakProbe == nil)
    }

    @Test("repeated free cycles do not accumulate retention or double release")
    func repeatedFreeCyclesRemainBounded() {
        for _ in 0..<128 {
            var callbackCount = 0
            var probe: LifetimeProbe? = LifetimeProbe()
            weak var weakProbe = probe
            let retention = GhosttySurfaceFreeRetention(
                object: probe!,
                onRelease: { callbackCount += 1 }
            )
            probe = nil

            #expect(weakProbe != nil)
            #expect(retention.releaseAfterSurfaceFree())
            #expect(!retention.releaseAfterSurfaceFree())
            #expect(callbackCount == 1)
            #expect(weakProbe == nil)
        }
    }
}

private final class LifetimeProbe {}

#endif
