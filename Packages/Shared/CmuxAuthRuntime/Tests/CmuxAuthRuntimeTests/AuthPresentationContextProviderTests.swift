#if os(macOS)
import AppKit
import Testing
@testable import CmuxAuthRuntime

/// Pins the zombie-window hardening from
/// https://github.com/manaflow-ai/cmux/issues/7825: when the app has no
/// window to anchor to, the fallback anchor must stay invisible and must
/// never be made key. (The historical fallback called `makeKey()` on a bare
/// `NSWindow`, which shows up as an empty black window if AppKit ever orders
/// it in.) This documents the invariant; the deterministic red/green proof
/// for #7825 itself lives in `cmuxTests/ExternalURLOpenWindowRegressionTests`.
@MainActor
@Suite struct AuthPresentationContextProviderTests {
    @Test func anchorPrefersExistingWindowsAndFallbackStaysInvisible() {
        let provider = AuthPresentationContextProvider()
        let anchor = provider.resolveAnchor()
        if NSApplication.shared.windows.contains(anchor) {
            // A real app window (test-host dependent) is a valid anchor.
            return
        }
        // No app window existed: the constructed fallback must be inert.
        #expect(!anchor.isVisible)
        #expect(!anchor.isKeyWindow)
    }
}
#endif
