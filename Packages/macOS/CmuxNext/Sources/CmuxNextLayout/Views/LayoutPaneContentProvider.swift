public import AppKit
public import CmuxNextDesign
import CmuxNextInput
import CmuxNextWakeups

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
    /// What pages in a pane do while it springs, given to each pane host as it is made
    /// (`RestingPlacement.pageResizing`); nil: they resize with the pane.
    var pageSpringResizing: PageSpringResizing? { get }
}

extension LayoutPaneContentProvider {
    public func releaseContentView(_ view: NSView, for pane: PaneID) {}
    public func panePresenceDidChange(_ pane: PaneID, presence: PanePresence) {}
    public var pageSpringResizing: PageSpringResizing? { nil }
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
    /// Pane hosts went to rest at a render-server spring's start: the overlay plane places their chrome
    /// there now, so each host's springs carry its chrome in the same group (`LayoutRootView.syncOverlayNow`).
    var overlaySyncNow: () -> Void = {}
    /// A rect in a view's coordinates, in the overlay plane's (the root's): where a host's chrome rides from
    /// (`PaneHostView.springToRest`). Nil without a root.
    var overlayPlaneRect: (CGRect, NSView) -> CGRect? = { _, _ in nil }
    /// A user gesture moves the layout (a strip, row or scroll-area pan with the finger down): the root reads
    /// as in layout motion until the motion after it lands (`LayoutRootView.setLayoutInMotion`).
    var userMotionStepped: () -> Void = {}
    /// A user gesture ended, or a screen's render-server springs landed, with nothing left to spring: the motion
    /// it started ends.
    var userMotionEnded: () -> Void = {}
    /// A screen's render-server springs all landed, a pan held across the landing or not: the visibility pass
    /// narrows to the rest (`LayoutRootView.updateVisibilityIfPlanChanged`).
    var renderSpringsLanded: () -> Void = {}
    /// Whether the window shows content in child windows placed from pane frames (Chromium pages,
    /// R3): those windows follow host frames, not a layer translation, so a strip pan moves the
    /// frames then (`ScreenContentView.pansOnContainer`).
    var childWindowContentShows: () -> Bool = { false }
    /// A screen's strip started or stopped showing away from where its views are laid out
    /// (`StripClipContainerView.showsMoved`).
    var stripMovedDidChange: () -> Void = {}
    /// A change turn handed a screen's springs to the render server: the window's `motion.run` begins
    /// (`LayoutMotionTrace`); its landing ends it through ``userMotionEnded``.
    var renderMotionBegan: () -> Void = {}
    /// A pane's clip changed (the strip container's range, an area mask, a zooming pane over it):
    /// Chromium pages re-read their clips.
    var stripClipsDidChange: () -> Void = {}
    /// Screens whose panes spring to a split's or a close's sizes now (`ScreenContentView.holdsGrids`).
    var gridHoldScreens: Set<ScreenID> = [] {
        didSet { if oldValue.isEmpty != gridHoldScreens.isEmpty { gridHoldDidChange(!gridHoldScreens.isEmpty) } }
    }
    /// The first split or close started (true) or the last one landed (false): `LayoutRootView.onTerminalGridHold`.
    var gridHoldDidChange: (Bool) -> Void = { _ in }
    /// Presses the root's intercept handled while render-server springs ran on its active screen
    /// (`ScreenContentView.pressedPane(at:)`, `LayoutRootView.pressesMidRenderSpring`), cumulative.
    var pressesMidRenderSpring = 0
    /// Scrolls the root's intercept sent through its full routing, with its pane hit tests and claim
    /// queries (`LayoutRootView.routedScrolls`), cumulative; a page's plain scroll takes none.
    var routedScrolls: UInt64 = 0
    /// Scroll points the root's intercept converted from a child window into its own
    /// (`LayoutRootView.scrollPointConversions`), cumulative; a page's plain scroll takes none.
    var scrollPointConversions: UInt64 = 0
    /// The strip scrollbar's fade-out deadline clock.
    let scrollbarClock: any Clock<Duration>
    /// Where the pointer is now, in `window`'s coordinates; nil when it cannot
    /// hover there (the window is not key). The event is the handle's enter or
    /// exit being handled: its own point is read, not the live cursor. Cheap:
    /// also read on every frame that moves the layout, with no event at hand,
    /// because the layout can move under a still pointer.
    var hoverPointer: @MainActor (NSWindow, NSEvent?) -> NSPoint? = { _, _ in nil }
    /// Whether the window is on top at the point `hoverPointer` gave (`window`'s
    /// coordinates; no other window or panel covers it, except pass-through
    /// panels). A window server round trip: asked only when a handle is under
    /// the pointer.
    var hoverReachesWindow: @MainActor (NSWindow, NSPoint) -> Bool = { _, _ in false }
    /// Windows above this one that pass divider hover through: the app's
    /// click-catching panels over page windows (`DividerMouseCatchers`).
    var hoverPassThroughWindows: () -> Set<Int> = { [] }
    /// Where the root hears its window's key changes (`LayoutRootView.observeKeyWindow()`): the
    /// app's one ``WindowEvents`` per window; tests pass their own on their own center.
    var hoverWindowEvents: @MainActor (NSWindow) -> WindowEvents = { WindowEvents.of($0) }
    /// The windows' frame-aligned pointer input for divider drags (``LayoutRootView/dragFrameInput``);
    /// nil: each drag event moves the divider at once.
    var dragFrameInput: FrameInputCoalescers?
    /// A new divider drag's resampler (``LayoutRootView/dragResampler``); nil: drawn at the real pointer.
    var dragResampler: () -> DragResampler? = { nil }
    /// A strip pan on the motion container shows at each display frame's time, resampled
    /// (feature `stripPanResampling`, ``LayoutRootView/resamplesStripPan``).
    var resamplesStripPan = false

    /// Whether layout motion runs on the render server (`motion.renderServer`): every host's
    /// `MotionBackends` reads it once per change turn, and only with a variant registered.
    let rendersMotionOnServer: () -> Bool

    init(model: LayoutModel, provider: any LayoutPaneContentProvider, scrollbarClock: any Clock<Duration> = ContinuousClock(),
         rendersMotionOnServer: @escaping () -> Bool = { LayoutTunables.motionRenderServer.value }) {
        self.model = model
        self.provider = provider
        self.scrollbarClock = scrollbarClock
        self.rendersMotionOnServer = rendersMotionOnServer
        // The shared pointer source (`PointerHover`, CmuxNextDesign): the
        // real pointer while the window is key and visible, `debug.mouse`'s
        // synthesized pointer in DEBUG builds (it also passes the topmost check).
        hoverPointer = { window, event in PointerHover.pointer(in: window, requireKey: true, event: event) }
        hoverReachesWindow = { [weak self] window, point in
            PointerHover.isTopmost(window, at: point, passThrough: self?.hoverPassThroughWindows() ?? [])
        }
    }

    var style: LayoutStyle { model.style }

    /// Pins Reduce Motion for this view only (tests), instead of the
    /// process-wide `Motion.reduceMotionOverride`, which leaks into every
    /// test that runs while an async test is suspended.
    var reduceMotionOverride: Bool?

    /// Movement snaps: Reduce Motion or `ui.animationSpeed` "off" (`Motion`).
    var reduceMotion: Bool { reduceMotionOverride ?? !Motion.panes.animatesMovement }

    /// Pane layout changes spring (`ui.paneAnimations`, on by default; plans/cmux-next/motion.md rule 9).
    /// A test that pins `reduceMotionOverride` pins this too, so its springs run as before the setting.
    var animatesPaneLayout: Bool { reduceMotionOverride.map { !$0 } ?? Motion.panes.animatesPaneLayout }

    /// A new drag's resampler (``dragResampler``); none under Reduce Motion, where a drag is drawn at the
    /// real pointer.
    func newDragResampler() -> DragResampler? {
        reduceMotion ? nil : dragResampler()
    }

    func host(for pane: PaneID) -> PaneHostView {
        if let host = hosts[pane] { return host }
        let content = provider?.makeContentView(for: pane) ?? NSView()
        let host = PaneHostView(pane: pane, content: content, pageResizing: provider?.pageSpringResizing)
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
