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
/// on top of it shows at a claim. Without it the page keeps its own frame for its move into a pane
/// (``AgentPageRedraw/rememberFrame(of:appearance:completion:)``) and then sleeps too: its page view hides
/// once that capture finished, wakes for a later capture of the app's New Tab frame (a late
/// `chats.page` answer) and sleeps again after it, and shows at the claim (trunk #26975, which
/// suspended the parked spare's renderer after its warm frame).
@MainActor
public final class AgentPanePreloadPage: PreloadablePage {
    /// The New Tab pane the slot holds.
    public let pane: AgentPaneView
    /// The page waits hidden and gives the slot its cover.
    public let parksHidden: Bool
    /// Without ``parksHidden``: parked (captured, not claimed), so a finished capture may hide the page.
    private var parked = false
    /// Only the latest capture's completion may put the page to sleep.
    private var sleepGeneration: UInt64 = 0

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
            parked = true
            rememberThenSleep()
            return body(nil)
        }
        guard !pane.pageDrawsOverCovers, let webKit = pane.page.webKitEngine else { return body(nil) }
        webKit.takeSnapshot(with: nil) { image, _ in
            body(image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        }
    }

    /// Hides or shows the page view. A page that parks rendering hides only by itself, after its
    /// capture (``rememberThenSleep()``); shown, it is no longer parked and no capture hides it.
    public func preloadSetVisible(_ visible: Bool) {
        if !parksHidden {
            guard visible else { return }
            parked = false
            sleepGeneration &+= 1
            pane.redraw.newTabFrameCaptureChanged = nil
        }
        if pane.page.isHidden == visible { pane.page.isHidden = !visible }
    }

    /// Keeps the page's frame for its move into a pane, then hides the page view: a hidden view's
    /// renderer stops its animations and the transport holds nonurgent pushes until the claim. A
    /// capture of the app's New Tab frame meanwhile wakes it (it needs the renderer) and the page
    /// sleeps again once that capture ended.
    private func rememberThenSleep() {
        pane.redraw.newTabFrameCaptureChanged = { [weak self] capturing in
            guard let self, self.parked else { return }
            if capturing {
                // A late chats.page answer invalidates the first frame: awake through the new capture,
                // and no older completion hides it meanwhile.
                self.sleepGeneration &+= 1
                self.pane.page.isHidden = false
            } else {
                self.rememberThenSleep()
            }
        }
        guard !pane.redraw.givesNewTabFrame else { return }
        sleepGeneration &+= 1
        let generation = sleepGeneration
        // Rendering until this capture finished, also after a parked refit.
        pane.page.isHidden = false
        pane.redraw.rememberFrame(of: pane, appearance: pane.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])) { [weak self] in
            guard let self, self.parked, self.sleepGeneration == generation else { return }
            self.pane.page.isHidden = true
        }
    }

    /// No freeze yet: WebKit has none, and the page view has no Chromium freeze until p13-webui-028
    /// gives it `setFrozen(_:)`. The slot then keeps the page hidden and running.
    public func preloadFreeze() -> Bool { false }

    /// Never frozen (``preloadFreeze()``), so nothing to thaw.
    public func preloadThaw() {}

    public func close() {
        parked = false
        pane.redraw.newTabFrameCaptureChanged = nil
        pane.close()
    }
}
