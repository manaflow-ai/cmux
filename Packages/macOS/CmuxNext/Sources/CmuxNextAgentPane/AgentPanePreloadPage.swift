public import AppKit
public import CmuxNextPages
import WebKit

/// A New Tab agent pane as the app's one preload (``PagePreloadSlot``): the slot
/// holds the pane in its parking and hands it to Cmd-T in the key's turn. Its own type, not an
/// ``AgentPaneView`` conformance, so the pane's type does not grow.
///
/// With ``parksHidden`` (feature `newTabParksHidden`) the slot takes the page's first frame as its
/// cover and hides the page while parked. Visibility is the page view's own hidden state, so both
/// engines learn it the way a tab switch tells them: WebKit reads it from AppKit, and ``PageWebView``
/// tells its Chromium page on hide and unhide. The pane itself stays unhidden, so the slot's cover
/// on top of it shows at a claim. Without it the page waits rendering, as the New Tab spare always
/// did, and keeps its own frame for its move into a pane (``AgentPageRedraw/rememberFrame(of:appearance:)``).
@MainActor
public final class AgentPanePreloadPage: PreloadablePage {
    /// The New Tab pane the slot holds.
    public let pane: AgentPaneView
    /// The page waits hidden and gives the slot its cover.
    public let parksHidden: Bool

    public init(pane: AgentPaneView, parksHidden: Bool) {
        self.pane = pane
        self.parksHidden = parksHidden
    }

    public var preloadView: NSView { pane }

    /// The page's id on the `webui.*` trace tracks (its page view's address, as ``PageWebView`` uses).
    public var preloadTraceID: UInt64 { UInt64(UInt(bitPattern: ObjectIdentifier(pane.page))) }

    /// After the first paint of the page's document, its next frame on screen (``AgentPageRedraw/afterNextFrame(_:)``).
    public func preloadWhenPainted(_ body: @escaping @MainActor () -> Void) {
        pane.model.whenPainted { [weak pane] in
            guard let pane else { return body() }
            pane.redraw.afterNextFrame { body() }
        }
    }

    /// The WebKit engine's picture of the page as it draws now, the slot's cover. None for a Chromium page:
    /// Chromium draws in its own window over the pane, so a cover under it shows through its clear
    /// areas (2026-10-24), and its picture paints those areas black. None while the page waits
    /// rendering: it keeps its own frame, at the size it painted, for its move into a pane.
    public func preloadCaptureCover(_ body: @escaping @MainActor (CGImage?) -> Void) {
        guard parksHidden else {
            pane.redraw.rememberFrame(of: pane, appearance: pane.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]))
            return body(nil)
        }
        guard !pane.pageDrawsOverCovers, let webKit = pane.page.webKitEngine else { return body(nil) }
        webKit.takeSnapshot(with: nil) { image, _ in
            body(image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        }
    }

    /// Hides or shows the page view; a page that waits rendering stays shown.
    public func preloadSetVisible(_ visible: Bool) {
        guard parksHidden || visible else { return }
        if pane.page.isHidden == visible { pane.page.isHidden = !visible }
    }

    /// No freeze yet: WebKit has none, and the page view has no Chromium freeze until p13-webui-028
    /// gives it `setFrozen(_:)`. The slot then keeps the page hidden and running.
    public func preloadFreeze() -> Bool { false }

    /// Never frozen (``preloadFreeze()``), so nothing to thaw.
    public func preloadThaw() {}

    public func close() { pane.close() }
}
