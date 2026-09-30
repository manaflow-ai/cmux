public import AppKit
import CmuxNextDesign

/// Supplies the view hosted in each pane. The layout does not know about
/// terminals or browsers; the App returns a view containing the tab strip
/// and the active tab's content.
///
/// Views stay alive and in the hierarchy while scrolled offscreen or on an
/// inactive screen. Use `panePresenceDidChange` (or `LayoutModel.visiblePanes`
/// and `keepAlivePanes`) to pause rendering for occluded panes and to release
/// content of panes far from the viewport.
public protocol LayoutPaneContentProvider: AnyObject {
    /// Creates the view for a pane the first time it appears.
    func makeContentView(for pane: PaneID) -> NSView
    /// The pane left the layout. Called in the same update, with no removal animation.
    func releaseContentView(_ view: NSView, for pane: PaneID)
    /// The pane scrolled on screen, into the keep-alive band, or away (other
    /// screen, far scroll). Panes start `.hidden`.
    func panePresenceDidChange(_ pane: PaneID, presence: PanePresence)
}

extension LayoutPaneContentProvider {
    public func releaseContentView(_ view: NSView, for pane: PaneID) {}
    public func panePresenceDidChange(_ pane: PaneID, presence: PanePresence) {}
}

/// Pasteboard type for tab drags the layout accepts through AppKit drag and
/// drop. The pasteboard string is the `TabID` raw value. Put only this type
/// on the pasteboard, or hosted views that accept strings take the drop.
public enum LayoutTabDrag {
    public static let pasteboardType = NSPasteboard.PasteboardType("com.cmuxterm.next.layout.tab")
}

/// Shared state between the root view and its screen views.
final class LayoutViewContext {
    let model: LayoutModel
    weak var provider: (any LayoutPaneContentProvider)?
    private(set) var hosts: [PaneID: PaneHostView] = [:]
    /// Panes present in any screen of the current snapshot.
    var livePanes: Set<PaneID> = []
    var requestFrames: () -> Void = {}
    /// Pane hosts or dividers moved: the overlay plane follows them.
    var overlayNeedsSync: () -> Void = {}

    init(model: LayoutModel, provider: any LayoutPaneContentProvider) {
        self.model = model
        self.provider = provider
    }

    var style: LayoutStyle { model.style }

    /// Movement snaps: Reduce Motion or `ui.animationSpeed` "off" (`Motion`).
    var reduceMotion: Bool { !Motion.animatesMovement }

    func host(for pane: PaneID) -> PaneHostView {
        if let host = hosts[pane] { return host }
        let content = provider?.makeContentView(for: pane) ?? NSView()
        let host = PaneHostView(pane: pane, content: content)
        hosts[pane] = host
        return host
    }

    func release(_ pane: PaneID) {
        guard let host = hosts.removeValue(forKey: pane) else { return }
        host.removeFromSuperview()
        host.chrome.removeFromSuperview()
        provider?.releaseContentView(host.content, for: pane)
    }
}
