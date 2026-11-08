import Foundation
import WebKit

/// WebKit's own page mute (`-[WKWebView _setPageMuted:]`, WebKit SPI, Safari's Mute Tab): every
/// sound of the page, Web Audio and every frame too, which the media script cannot reach. WebKit
/// keeps it across navigations and a WebContent process restart.
extension WebKitTab {
    /// `_WKMediaAudioMuted` in `_WKMediaMutedState`; the other bits mute camera, microphone and
    /// screen capture, which the tab's mute leaves as they are.
    private static let audioMutedBit = 1

    /// Whether WebKit mutes the page's audio now; nil when this WebKit has no page mute SPI.
    var isPageAudioMuted: Bool? {
        mutedState().map { $0 & Self.audioMutedBit != 0 }
    }

    /// Mutes or unmutes the page's audio in WebKit as the tab's state says.
    func applyAudioMute() {
        let setter = NSSelectorFromString("_setPageMuted:")
        // crash-allow: WebKit private selectors, only called after responds(to:) (no unknown-selector exception).
        guard let current = mutedState(), webView.responds(to: setter) else { return }
        let wanted = state.isAudioMuted ? current | Self.audioMutedBit : current & ~Self.audioMutedBit
        guard wanted != current else { return }
        typealias SetMuted = @convention(c) (AnyObject, Selector, Int) -> Void
        unsafeBitCast(webView.method(for: setter), to: SetMuted.self)(webView, setter, wanted)
    }

    private func mutedState() -> Int? {
        let getter = NSSelectorFromString("_mediaMutedState")
        // crash-allow: WebKit private selector, only called after responds(to:).
        guard webView.responds(to: getter) else { return nil }
        typealias Get = @convention(c) (AnyObject, Selector) -> Int
        return unsafeBitCast(webView.method(for: getter), to: Get.self)(webView, getter)
    }
}
