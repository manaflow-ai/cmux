public import WebKit

/// Page-level audio muting via WebKit's private `_setPageMuted:` SPI.
///
/// WebKit exposes per-media-element muting through public API, but cmux needs to
/// mute the whole page's audio (for backgrounded browser surfaces) and the
/// deployable SDK surface has no stable public accessor for that. These helpers
/// reach `_setPageMuted:` through the audited `@convention(c)` IMP path, guarded
/// by a `responds(to:)` check so a future WebKit that drops the selector degrades
/// to a no-op instead of crashing.
extension WKWebView {
    /// The `_setPageMuted:` SPI selector.
    nonisolated private static var cmuxSetPageMutedSelector: Selector {
        NSSelectorFromString("_setPageMuted:")
    }

    /// The WebKit `_WKMediaMutedState` bit for audio muting (`1 << 0`).
    nonisolated private static var cmuxMediaMutedStateAudio: Int {
        1 << 0
    }

    /// Mutes or unmutes all audio playing in this web view's page.
    ///
    /// Returns `true` when the SPI was invoked, `false` when this WebKit build
    /// does not respond to `_setPageMuted:` (no muting happens in that case).
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
}
