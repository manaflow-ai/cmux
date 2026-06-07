import Testing
@testable import CmuxMobileShellUI

/// CmuxMobileShellUI is UIKit-bound and iOS-only; its behavior is exercised by
/// the app build and the lower-layer packages' suites. This smoke test keeps the
/// test target valid for simulator-destination CI runs.
@Suite struct CmuxMobileShellUISmokeTests {
    @Test func moduleLinks() {
        #expect(Bool(true))
    }
}
