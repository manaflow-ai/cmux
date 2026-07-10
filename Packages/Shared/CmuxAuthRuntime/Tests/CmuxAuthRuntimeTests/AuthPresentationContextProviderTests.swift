#if os(macOS)
import AppKit
import Testing

@testable import CmuxAuthRuntime

/// Pins the zombie-window hardening from
/// https://github.com/manaflow-ai/cmux/issues/7825 through the injectable
/// `resolveAnchor(keyWindow:mainWindow:firstWindow:)` seam, so every branch —
/// most importantly the no-window fallback — is exercised deterministically
/// regardless of the test host's live window state. The deterministic
/// red/green proof for #7825 itself lives in
/// `cmuxTests/ExternalURLOpenWindowRegressionTests`.
@MainActor
@Suite struct AuthPresentationContextProviderTests {
    @Test func fallbackAnchorWithNoWindowsStaysInvisibleAndNonKey() {
        let provider = AuthPresentationContextProvider()
        let anchor = provider.resolveAnchor(keyWindow: nil, mainWindow: nil, firstWindow: nil)
        // The historical fallback called makeKey() on a bare NSWindow, which
        // shows up as an empty black window if AppKit ever orders it in.
        #expect(!anchor.isVisible)
        #expect(!anchor.isKeyWindow)
    }

    @Test func anchorPrefersKeyWindowThenMainWindowThenFirstWindow() {
        let provider = AuthPresentationContextProvider()
        let key = NSWindow()
        let main = NSWindow()
        let first = NSWindow()
        #expect(provider.resolveAnchor(keyWindow: key, mainWindow: main, firstWindow: first) === key)
        #expect(provider.resolveAnchor(keyWindow: nil, mainWindow: main, firstWindow: first) === main)
        #expect(provider.resolveAnchor(keyWindow: nil, mainWindow: nil, firstWindow: first) === first)
    }
}
#endif
