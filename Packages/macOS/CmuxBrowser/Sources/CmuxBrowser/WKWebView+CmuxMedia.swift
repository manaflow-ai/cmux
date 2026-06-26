public import WebKit

extension WKWebView {
    nonisolated private static var cmuxSetPageMutedSelector: Selector {
        NSSelectorFromString("_setPageMuted:")
    }

    nonisolated private static var cmuxMediaMutedStateAudio: Int {
        1 << 0
    }

    /// Mutes or unmutes the page's audio output using WebKit's private
    /// `_setPageMuted:` SPI, returning `true` only when the receiver responds to
    /// the selector and the call was dispatched.
    @discardableResult
    public func cmuxSetPageAudioMuted(_ muted: Bool) -> Bool {
        let selector = Self.cmuxSetPageMutedSelector
        guard responds(to: selector),
              let implementation = method(for: selector) else {
            return false
        }

        typealias SetPageMutedFunction = @convention(c) (AnyObject, Selector, Int) -> Void
        let function = unsafeBitCast(implementation, to: SetPageMutedFunction.self)
        function(self, selector, muted ? Self.cmuxMediaMutedStateAudio : 0)
        return true
    }

    /// Whether the web view's element fullscreen is active or mid-transition, so
    /// callers can treat entering/exiting fullscreen the same as fully in it.
    public var cmuxIsElementFullscreenActiveOrTransitioning: Bool {
        switch fullscreenState {
        case .notInFullscreen:
            return false
        case .enteringFullscreen, .inFullscreen, .exitingFullscreen:
            return true
        @unknown default:
            return true
        }
    }
}
