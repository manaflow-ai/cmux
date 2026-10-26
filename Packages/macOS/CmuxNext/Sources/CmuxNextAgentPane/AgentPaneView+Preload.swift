public import AppKit
public import CmuxNextPages
import WebKit

/// The New Tab agent pane as the app's one preload (``PagePreloadSlot``, p13-webui-044): the slot
/// holds the pane in its parking, takes its first frame as the cover, hides it and (with
/// ``PagePreloadSlot/ParkState/frozenHidden``) freezes it, and hands it to Cmd-T in the key's turn.
///
/// Visibility is the page view's own hidden state, so both engines learn it the way a tab switch
/// tells them: WebKit reads it from AppKit, and ``PageWebView`` tells its Chromium page on hide and
/// unhide. The pane itself stays unhidden, so the slot's cover on top of it shows at a claim.
extension AgentPaneView: PreloadablePage {
    public var preloadView: NSView { self }

    /// The page's id on the `webui.*` trace tracks (its page view's address, as ``PageWebView`` uses).
    public var preloadTraceID: UInt64 { UInt64(UInt(bitPattern: ObjectIdentifier(page))) }

    /// After the first paint of the page's document, its next frame on screen (``AgentPageRedraw/afterNextFrame(_:)``).
    public func preloadWhenPainted(_ body: @escaping @MainActor () -> Void) {
        model.whenPainted { [weak self] in
            guard let self else { return body() }
            self.redraw.afterNextFrame { body() }
        }
    }

    /// WebKit's picture of the page as it draws now. None for a Chromium page: Chromium draws in its
    /// own window over the pane, so a cover under it shows through its clear areas (2026-10-24), and
    /// its picture paints those areas black.
    public func preloadCaptureCover(_ body: @escaping @MainActor (CGImage?) -> Void) {
        guard !pageDrawsOverCovers, page.snapshotKeepsClearAreas else { return body(nil) }
        webView.takeSnapshot(with: nil) { image, _ in
            body(image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        }
    }

    public func preloadSetVisible(_ visible: Bool) {
        if page.isHidden == visible { page.isHidden = !visible }
    }

    public func preloadFreeze() { page.freezeParkedPreload() }

    public func preloadThaw() { page.thawParkedPreload() }
}
