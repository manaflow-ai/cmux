import Foundation
@testable import CmuxNextPalette
import Testing

/// cx-ouiw, cx-35yk: the shared ranker is a built bundle (`palette-ranker.js`, build output since
/// cx-vn5). When it could not load, the ranker answered every page with no rows and said nothing,
/// so a run without the bundle failed as 30 PaletteInputStepTests issues and 40 recorder issues
/// with no cause in sight. A ranker that cannot load keeps the reason and says it once.
@Suite struct PaletteRankerLoadTests {
    @Test func aRankerWhoseBundleCannotLoadKeepsTheReason() {
        let ranker = PaletteRanker(loading: { throw PaletteRankerBridgeError.resourceMissing })
        guard case .resourceMissing? = ranker.loadError else {
            Issue.record("expected resourceMissing, got \(String(describing: ranker.loadError))")
            return
        }
    }

    @Test func theSharedRankerBundleLoads() {
        let error = PaletteRanker().loadError
        #expect(error == nil, """
            The palette ranker did not load (\(error?.localizedDescription ?? "")): every palette page \
            has no rows and the palette suites fail. Build the web bundles first: \
            scripts/cmux-next/build-web-bundles.sh (fleet runs: scripts/ci/ensure-web-bundles.sh).
            """)
    }
}
