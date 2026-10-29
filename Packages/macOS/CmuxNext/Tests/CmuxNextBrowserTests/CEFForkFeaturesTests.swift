@testable import CmuxNextBrowser
import Testing

/// The p14 fork bundle is one API number: the first after the resize fence, and the one
/// the Energy Saver call waits for, so a fork at the fence (API 32) or below gets no saver call.
@MainActor
@Suite struct CEFForkFeaturesTests {
    @Test func theP14BundleIsTheFirstAPIAfterTheResizeFence() {
        #expect(CEFForkFeatures.p14BundleForkAPI == CEFLayerHosting.resizeFenceForkAPI + 1)
        #expect(CEFForkFeatures.energySaverForkAPI == CEFForkFeatures.p14BundleForkAPI)
    }

    @Test func energySaverStartsAtTheBundle() {
        let fence = CEFForkFeatures(forkAPIVersion: CEFLayerHosting.resizeFenceForkAPI, shimHasRendererPaths: true)
        let bundle = CEFForkFeatures(forkAPIVersion: CEFForkFeatures.p14BundleForkAPI, shimHasRendererPaths: false)
        #expect(!fence.energySaver)
        #expect(bundle.energySaver)
    }
}
