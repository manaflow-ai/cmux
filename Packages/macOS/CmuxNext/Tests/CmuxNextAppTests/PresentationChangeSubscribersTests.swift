import Foundation
import Testing
@testable import CmuxNextApp
@testable import CmuxNextBrowserHost

/// A presentation change (a tab shown, hidden or released) reaches every
/// subscriber: the blank-pane invariant, the input invariant monitor and the
/// browser host provider, which re-reads its tab list (`visible` is not
/// observable, so the host learns it only from this push). Before cx-x3t9 input
/// verification replaced the cache's single callback and the browser host
/// never heard of a presentation change.
@Suite struct PresentationChangeSubscribersTests {
    @Test func aPresentationChangeReachesTheBrowserHostProvider() throws {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let provider = try #require(services.browserHost?.provider)
        let before = provider.observation
        services.cache.release("cx-x3t9-no-such-tab")
        #expect(provider.observation > before, "the browser host re-reads its tabs on a presentation change")
    }
}
