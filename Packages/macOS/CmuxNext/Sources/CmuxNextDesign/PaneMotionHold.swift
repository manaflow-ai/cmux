public import AppKit

/// The edges of a pane that stay while a keyboard resize moves it, as a value (FRAME OWNER REFACTOR S1). The pane hands
/// it down its view tree. Every view (the tab strip, the content area, a page, a chat) takes the pane's rect in each
/// frame; what draws its pixels on another thread or in another process (a terminal surface, a Chromium page) reads
/// these edges to place a frame that is late, and hears once when the motion ends.
public nonisolated struct PaneMotionHold: Equatable, Sendable {
    /// The held content's trailing edge rides the pane's trailing edge (false: its leading edge rides the leading one).
    public var trailing: Bool
    /// Its bottom edge rides the pane's bottom edge (false: its top edge rides the top one).
    public var bottom: Bool

    public init(trailing: Bool, bottom: Bool) {
        self.trailing = trailing
        self.bottom = bottom
    }

    /// Where a producer `size` big sits on these edges of `area`, in a view that is not flipped (FRAME OWNER S3): its
    /// edge on the side that does not move stays put, and the moving edge of a growing pane uncovers it.
    public func producerFrame(_ size: CGSize, in area: CGRect) -> CGRect {
        CGRect(x: trailing ? area.maxX - size.width : area.minX, y: bottom ? area.minY : area.maxY - size.height,
               width: size.width, height: size.height)
    }
}

/// Pane content that follows the pane in every frame of a hold (FRAME OWNER REFACTOR S1): its tab strip and what its
/// content area shows lay out at the pane's rect in the frame's tick, and the area tells the hold to the producers in it.
/// Content with no area (nil; a view that is not a pane's own content view) is held whole by its pane host.
@MainActor
public protocol PaneMotionHolding: NSView {
    /// The area that hears the hold while the content follows the pane, or nil to be held whole.
    var paneMotionHoldArea: PaneContentAreaView? { get }
}

/// THE EXCEPTION to "what a pane shows has its content area's size in every frame of a keyboard resize"
/// (``PaneContentAreaView``): pane content that states this keeps the size it had when the hold began, on the hold's
/// edges, cut by the area where the pane is smaller and beside the area's ground where it is larger, and takes the
/// pane's size once, after the landing. That is what every page did before 2026-11-11.
///
/// Following is the default; a kind takes this only with a measured reason and the work that ends it, stated here.
/// Not a setting, and no way out for a new kind whose layout is slow per frame: fix that layout.
///
/// THE ONE CONFORMANCE: the app's internal page view, for the docked Home and the Home page tab only
/// (`InternalPageView.holdsInKeyResize`).
///
/// Reason, measured (Release builds, aws-m4pro-8, macOS 26.7, 120 Hz, hold mx5 of cmux#41105, 3 takes each): when the
/// Home followed, the motion missed 13 to 15 of about 125 refreshes at a moving pane (docked Home) and 7 to 22 (Home
/// page tab), each second refresh in the first 8 frames after each key press; held, 0. The frame's layout pass took
/// 2.8 ms at the median and 5.6 ms at p95, against 0.9 ms and 1.3 ms held. A main-thread sample puts the cost in the
/// Home's own layout at each new width (`HomeNativeTranscriptView.layout`, the first-run panel's fitting size, the
/// SwiftUI message list's render). A Home that follows and drops each second refresh stutters the whole window, so it
/// stays held until that layout costs no missed refresh. All of these numbers are of the empty Home with the first-run
/// panel; a long transcript was not measured.
///
/// Ends with: the Home layout cost work of the pane-resize order (PR 3 of cmux#41105's series: a seeded Home of 50, 500
/// and 5000 rows, rows laid out per frame not growing with the row count). The commit that makes the Home follow
/// deletes this protocol and its conformance and moves the two pages from `HeldHome` to the kinds that follow in
/// `PaneContentFollowsPaneAllKindsTests`.
///
/// A conversation tab (the same Home view straight in the pane) is not in this: it followed its pane before
/// 2026-11-11 too, so it is not worse than it was.
@MainActor
public protocol PaneKeyResizeHeld: NSView {
    /// Whether it keeps its size through a keyboard resize now.
    var holdsInKeyResize: Bool { get }
}

/// A container in a pane's content area that hears the area's hold (FRAME OWNER REFACTOR S3: a terminal's host, a
/// browser's chrome), because its producer (the terminal surface, the page) draws its pixels on another thread or in
/// another process. Every view shown in the area takes the area's size in each frame; this one also gets the hold's
/// edges, once, and each frame's size ahead of its refresh, so its producer can have that frame ready: a terminal's
/// surface follows the area (cmux-ad m6, m18: each size shows with its frame, or, late, the last frame top-left in the
/// new bounds for a commit), a page lays out at the page area in each frame. Content that draws in this process, or
/// that lays out at once at each size (an internal page, a chat, Home), needs none of it and does not adopt this.
@MainActor
public protocol PaneMotionHoldFollowing: NSView {
    /// Whether it hears the hold now (a browser's chrome with no page in a window does not: it lays out live, as any view).
    var followsPaneMotion: Bool { get }
    /// The area holds on `hold`'s edges, from an area `heldSize` big when the hold began (the size the view had then);
    /// nil, nil: the hold ended, and the view's frame is the area's again. Called once per change, never per frame.
    func followPaneMotion(_ hold: PaneMotionHold?, heldSize: CGSize?)
    /// Draw ahead (cmux-ad m26): the pane's spring gives this follower `nextHostSize` at the next refresh. A producer that
    /// draws on another thread asks for that size now, after this refresh's commit, so its frame is ready when the refresh
    /// shows it. Called once per spring frame, only on followers of a hold.
    func drawAhead(nextHostSize: CGSize)
    /// Draw ahead of the hold's first frame (T-KEYS 3): a key press's spring gives this follower `nextHostSize` at its
    /// first refresh, the refresh whose layout hands it the hold. A producer that draws on another thread asks for that
    /// size in the key's turn, so the frame that shows the press is ready. Called once per press, in the key's turn, on
    /// the followers the hold will hand. `keyPress`: false for a snapped structural change (split, close, zoom with Reduce
    /// Motion or pane animations off, ``ScreenContentView`` `holdsSnapForContent`), which asks the size render only; a key
    /// press's size also takes its grid to the program (RESIZE P0 11).
    func drawAheadOfFollow(nextHostSize: CGSize, keyPress: Bool)
    /// A snapped change this follower's size was drawn ahead for showed (``ScreenContentView`` `presentHeldSnap`, RESIZE
    /// P0 14): a size drawn ahead that the change's placement did not take goes now. Until then only a placement at a new
    /// size may take it or drop it.
    func aheadOfFollowShown()
    /// Whether a key press's snap must keep waiting before it shows this follower's size drawn ahead
    /// (``drawAheadOfFollow(nextHostSize:keyPress:)`` with `keyPress`; Reduce Motion, RESIZE P0 20): its producer asked
    /// the program to redraw at the new size and has no frame of that redraw yet. `refreshesWaited`: the frame ticks the
    /// snap waited so far, counting the one asking (1 at the first). The follower bounds its own wait: false once it
    /// waited as long as it may.
    func aheadOfFollowAwaitsContent(refreshesWaited: Int) -> Bool
    /// A key press's held snap shows in this turn (RESIZE P0 21): its wait for the follower's content is over, so the
    /// placement it makes now shows the follower at its new size in the same commit, never its old size in the new pane.
    /// ``aheadOfFollowShown()`` follows in the same turn.
    func aheadOfFollowWillShow()
}

public extension PaneMotionHoldFollowing {
    var followsPaneMotion: Bool { true }
    func drawAhead(nextHostSize: CGSize) {}
    func drawAheadOfFollow(nextHostSize: CGSize, keyPress: Bool) {}
    func aheadOfFollowShown() {}
    func aheadOfFollowAwaitsContent(refreshesWaited: Int) -> Bool { false }
    func aheadOfFollowWillShow() {}
}
