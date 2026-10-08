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
public struct LayoutTabDrag {
    public init() {}
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
    /// The strip scrollbar's fade-out deadline clock.
    let scrollbarClock: any Clock<Duration>
    /// Where the pointer is now, in `window`'s coordinates; nil when it cannot
    /// hover there (the window is not key). Cheap: read on every frame that
    /// moves the layout, with no event at hand, because the layout can move
    /// under a still pointer.
    var hoverPointer: @MainActor (NSWindow) -> NSPoint? = { _ in nil }
    /// Whether the window is on top under the pointer (no other window or
    /// panel covers that point, except pass-through panels). A window server
    /// round trip: asked only when a handle is under the pointer.
    var hoverReachesWindow: @MainActor (NSWindow) -> Bool = { _ in false }
    /// Windows above this one that pass divider hover through: the app's
    /// click-catching panels over page windows (`DividerMouseCatchers`).
    var hoverPassThroughWindows: () -> Set<Int> = { [] }

    init(model: LayoutModel, provider: any LayoutPaneContentProvider, scrollbarClock: any Clock<Duration> = ContinuousClock()) {
        self.model = model
        self.provider = provider
        self.scrollbarClock = scrollbarClock
        hoverPointer = { window in Self.systemPointer(in: window) }
        hoverReachesWindow = { [weak self] window in
            Self.isTopmost(window, passThrough: self?.hoverPassThroughWindows() ?? [])
        }
    }

    #if DEBUG
    /// DEBUG: the pointer `debug.mouse` synthesized per window, in window
    /// coordinates; `.some(nil)` is a pointer outside the window.
    @MainActor static var debugPointers: [ObjectIdentifier: NSPoint?] = [:]
    #endif

    /// The real pointer in `window`'s coordinates while the window is key and
    /// visible (`debug.mouse`'s synthesized pointer in DEBUG builds).
    @MainActor static func systemPointer(in window: NSWindow) -> NSPoint? {
        #if DEBUG
        // `debug.mouse` drives a still real pointer: its synthesized pointer wins.
        if let synthetic = debugPointers[ObjectIdentifier(window)] { return synthetic }
        #endif
        guard window.isKeyWindow, window.isVisible else { return nil }
        return window.mouseLocationOutsideOfEventStream
    }

    /// The topmost window under the real pointer is `window` or a
    /// pass-through panel.
    @MainActor static func isTopmost(_ window: NSWindow, passThrough: Set<Int>) -> Bool {
        #if DEBUG
        if debugPointers[ObjectIdentifier(window)] != nil { return true }
        #endif
        let top = NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0)
        return top == window.windowNumber || passThrough.contains(top)
    }

    var style: LayoutStyle { model.style }

    /// Pins Reduce Motion for this view only (tests), instead of the
    /// process-wide `Motion.reduceMotionOverride`, which leaks into every
    /// test that runs while an async test is suspended.
    var reduceMotionOverride: Bool?

    /// Movement snaps: Reduce Motion or `ui.animationSpeed` "off" (`Motion`).
    var reduceMotion: Bool { reduceMotionOverride ?? !Motion.animatesMovement }

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
