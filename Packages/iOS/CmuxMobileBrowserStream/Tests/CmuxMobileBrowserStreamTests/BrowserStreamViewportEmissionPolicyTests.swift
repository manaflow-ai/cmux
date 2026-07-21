import CMUXMobileCore
import Testing
@testable import CmuxMobileBrowserStream

@Suite
struct BrowserStreamViewportEmissionPolicyTests {
    @Test
    func emitsOnlyRealViewportChanges() {
        let portrait = MobileBrowserViewport(width: 393, height: 740, scale: 3)
        let landscape = MobileBrowserViewport(width: 852, height: 321, scale: 3)
        var policy = BrowserStreamViewportEmissionPolicy()

        policy.record(portrait)
        #expect(policy.takePending() == portrait)
        policy.record(portrait)
        #expect(policy.takePending() == nil)
        policy.record(landscape)
        #expect(policy.takePending() == landscape)
    }

    @Test
    func coalescesLayoutBurstsToNewestViewport() {
        let first = MobileBrowserViewport(width: 393, height: 740, scale: 3)
        let final = MobileBrowserViewport(width: 393, height: 420, scale: 3)
        var policy = BrowserStreamViewportEmissionPolicy()

        policy.record(first)
        policy.record(final)
        #expect(policy.takePending() == final)
        #expect(policy.takePending() == nil)

        var reboundPolicy = BrowserStreamViewportEmissionPolicy()
        reboundPolicy.record(first)
        #expect(reboundPolicy.takePending() == first)
        reboundPolicy.record(final)
        reboundPolicy.record(first)
        #expect(reboundPolicy.takePending() == nil)
    }

    @Test
    func ignoresInvalidMeasurements() {
        var policy = BrowserStreamViewportEmissionPolicy()
        policy.record(MobileBrowserViewport(width: 0, height: 740, scale: 3))
        policy.record(MobileBrowserViewport(width: 393, height: 740, scale: 0))
        #expect(policy.takePending() == nil)
    }
}
