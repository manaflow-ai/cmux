#if DEBUG
import Testing
@testable import CmuxMobileShellUI

@Suite
struct MobileRootDebugPreviewRouteTests {
    @Test
    func panesPreviewRequiresExactEnabledValue() {
        #expect(MobileRootDebugPreviewRoute(environment: [
            "CMUX_UITEST_PANES_PREVIEW": "1",
        ]) == .panesTabs)
        #expect(MobileRootDebugPreviewRoute(environment: [:]) == nil)
        #expect(MobileRootDebugPreviewRoute(environment: [
            "CMUX_UITEST_PANES_PREVIEW": "0",
        ]) == nil)
        #expect(MobileRootDebugPreviewRoute(environment: [
            "CMUX_UITEST_PANES_PREVIEW": "true",
        ]) == nil)
    }
}
#endif
