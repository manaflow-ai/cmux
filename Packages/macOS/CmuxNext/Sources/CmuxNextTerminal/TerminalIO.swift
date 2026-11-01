public import AppKit
public import CmuxNextWakeups

/// Byte transport for one terminal, the seam between a Ghostty surface and
/// whatever owns the PTY.
///
/// The shape mirrors `CmuxNextDaemon.TerminalByteChannel` so the App layer can
/// bridge a daemon channel with a thin adapter. This module never imports the
/// daemon (plans/cmux-next/AGENT-BRIEF.md).
///
/// Ordering contract: `events` delivers bytes in PTY order. `write` calls are
/// issued by one consumer in the order Ghostty produced the input.
public nonisolated protocol TerminalIO: Sendable {
    /// Output, replay, geometry, and lifecycle events for this terminal.
    /// Consumed by exactly one ``TerminalSession``.
    var events: AsyncStream<TerminalIOEvent> { get }

    /// Encoded user input (keys, mouse reports, focus reports, bracketed
    /// paste) produced by Ghostty. Forward verbatim; Ghostty has already
    /// applied the mirrored terminal modes, so the owner must not re-wrap a
    /// paste.
    func write(_ data: Data) async

    /// Requests this view's grid when it owns canonical geometry. An IO that
    /// sends `.resize` events answers with one once the PTY has the size;
    /// one that does not must apply the size itself (the surface keeps
    /// fitting the view).
    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async

    /// Requests this view's grid on the main actor, in the caller's turn, instead of through the
    /// ordered ``resize(cols:rows:pixelWidth:pixelHeight:)``. `final`: the grid the view will have
    /// when its pane's layout spring lands, sent at the spring's start (a split or a close resizes
    /// the program in the terminal before the motion ends). Returns false when the IO has no
    /// main-actor path; the session then sends `resize` in order. `window`: the view's window, whose
    /// full screen transition holds the grid.
    @MainActor func resizeOnMain(cols: Int, rows: Int, final: Bool, window: NSWindow?) -> Bool

    /// True when the owner keeps its own VT state and answers terminal
    /// queries (DA, DSR, OSC color queries). The cmux-tui daemon does, so the
    /// surface runs in `GHOSTTY_SURFACE_IO_MANUAL_MIRROR` and Ghostty's parser
    /// replies are suppressed. A bare PTY does not, so the surface runs in
    /// `GHOSTTY_SURFACE_IO_MANUAL` and Ghostty replies (ghostty.h:552-559).
    var answersTerminalQueries: Bool { get }

    /// True while the grid this view reports becomes the PTY grid: the owner
    /// will announce it. The surface then draws its own reflow at the view's
    /// grid until the announcement (`ghostty_surface_set_reflow_preview`), so
    /// a resize shows on the same frame. `reporting`: the view reports a new
    /// grid now (a visible live view's report claims geometry). False while
    /// another client holds geometry, before the first replay, or when no
    /// owner announces grids.
    @MainActor func appliesViewGrid(reporting: Bool) -> Bool

    /// The grids this IO's link to the PTY owner holds (the size invariant, ``TerminalSizeInvariant``):
    /// the grid it last sent to the PTY and the grid the owner last announced. Nil (the default) for an
    /// IO that keeps no link, a bare local PTY.
    @MainActor var linkGrids: TerminalLinkGrids? { get }

    /// The surface gained keyboard focus. Ordered with `write` and `resize`.
    /// A daemon IO takes canonical geometry back if another client took it
    /// (the latest active client holds geometry).
    func focusGained() async

    /// Take over ("Sized for" chip): this view sets the grid with a new claim even when it
    /// believes it holds it. `setLatest`: the terminal's policy picks by size, so it becomes last
    /// active first. Ordered with `write`.
    func takeOverSize(setLatest: Bool) async

    /// The user clicked a disconnected terminal (``TerminalConnectionStatus``).
    /// A daemon IO re-attaches. Ordered with `write`.
    func reconnectRequested() async

    /// The surface's mirror cannot be trusted any more (a local-history
    /// restore did not match the owner's check): a daemon IO asks for a full
    /// snapshot. Ordered with `write`.
    func resyncRequested() async

    /// The name the typing probe gives this IO's terminal (``TypingLatencyProbe/Source``): the same one
    /// the attachment that sends its keys uses, so an echo counts only for the terminal that typed.
    /// Nil (the default): the probe takes no echo hop from this IO while a press is tied to a terminal.
    nonisolated var typingProbeSource: TypingLatencyProbe.Source? { get }
}

public extension TerminalIO {
    var answersTerminalQueries: Bool { true }
    @MainActor func appliesViewGrid(reporting: Bool) -> Bool { false }
    @MainActor var linkGrids: TerminalLinkGrids? { nil }
    @MainActor func resizeOnMain(cols: Int, rows: Int, final: Bool, window: NSWindow?) -> Bool { false }
    func focusGained() async {}
    func takeOverSize(setLatest: Bool) async {}
    func reconnectRequested() async {}
    func resyncRequested() async {}
    nonisolated var typingProbeSource: TypingLatencyProbe.Source? { nil }
}

/// One event from a ``TerminalIO``.
public nonisolated enum TerminalIOEvent: Sendable, Equatable {
    /// Full screen state to restore (a VT replay). The first replay goes into
    /// the fresh surface; a later one (reattach, daemon-side reflow) causes the
    /// session to swap in a new surface, because Ghostty has no reset API
    /// (cmux-tui-contract.md 3.2).
    case replay(Data)
    /// Replay that also carries Kitty graphics state. GhosttyNextKit has no
    /// kitty-replay restore; the session replays the VT part on a fresh
    /// surface until snapshot attach (terminal-snapshot-v1) restores images.
    case kittyReplay(TerminalKittyReplay)
    /// GHOSTSNP snapshot bytes from the PTY owner's terminal core
    /// (`ghostty_surface_restore_snapshot`), restored on the live surface in
    /// stream order. `ready` replaces the terminal state (send the grid as a
    /// `.resize` first); `history` continues the last READY with its
    /// scrollback. No surface swap.
    case snapshot(Data, phase: TerminalSnapshotPhase)
    /// Live PTY output, fed to `ghostty_surface_process_output`.
    case output(Data)
    /// The PTY's grid from this point in the stream (the daemon applied a
    /// size). Always applied with `ghostty_surface_set_grid` on the output
    /// lane; after the first one the surface renders only these grids. Send one for every
    /// size the PTY takes, including the initial one.
    case resize(cols: Int, rows: Int)
    /// The terminal's process exited. The surface stays readable.
    case exited
    /// The view's link to its terminal changed; the last screen stays.
    case status(TerminalConnectionStatus)
    /// Another view sets the terminal's grid and it does not fit this one: the view says for whom
    /// and offers Take over. Nil clears it.
    case sizedFor(TerminalSizedFor?)
}

/// "Sized for <device> · cols×rows" over a terminal whose grid another view sets
/// (plans/cmux-next/sync-ux/DESIGN.md 2.6).
public nonisolated struct TerminalSizedFor: Sendable, Equatable {
    /// The owner's device name (or its user's name); nil names it by `deviceKind`. Nil with
    /// `fixedSize`: nobody sets the grid, the terminal has a fixed size.
    public var deviceName: String?
    /// `mac`, `iphone`, `ipad`, `tui`, `browser`, `linux`, `windows` or `unknown`.
    public var deviceKind: String?
    /// The owner is another view on this device (another window of this Mac).
    public var sameDevice: Bool
    public var grid: TerminalGridSize
    /// The terminal has a fixed size (no view sets it): "Fixed size · cols×rows".
    public var fixedSize: Bool
    /// Take over sets the terminal's policy to last active before it claims: the policy picks by
    /// size (`smallest`, `largest`, `fixed`) or by rank (`priority` with a ranked view counting),
    /// so a claim alone would not move the grid (plans/cmux-next/sync-ux/DESIGN.md 2.6).
    public var takeOverSetsLatest: Bool

    public init(deviceName: String?, deviceKind: String?, sameDevice: Bool, grid: TerminalGridSize,
                fixedSize: Bool = false, takeOverSetsLatest: Bool = false) {
        self.deviceName = deviceName
        self.deviceKind = deviceKind
        self.sameDevice = sameDevice
        self.grid = grid
        self.fixedSize = fixedSize
        self.takeOverSetsLatest = takeOverSetsLatest
    }
}

/// Kitty graphics state that accompanies a replay (daemon `vt-state` /
/// `resized` fields `kitty_state` and `kitty_image_aliases`).
public nonisolated struct TerminalKittyReplay: Sendable, Equatable {
    public struct Cursors: Sendable, Equatable {
        public var primary: UInt32
        public var alternate: UInt32
        public init(primary: UInt32, alternate: UInt32) {
            self.primary = primary
            self.alternate = alternate
        }
    }

    public struct Limits: Sendable, Equatable {
        public var imageBytes: UInt64
        public var inflightBytes: UInt64
        public var images: UInt64
        public var placements: UInt64
        public init(imageBytes: UInt64, inflightBytes: UInt64, images: UInt64, placements: UInt64) {
            self.imageBytes = imageBytes
            self.inflightBytes = inflightBytes
            self.images = images
            self.placements = placements
        }
    }

    public struct Alias: Sendable, Equatable {
        public var imageID: UInt32
        public var imageNumber: UInt32
        public init(imageID: UInt32, imageNumber: UInt32) {
            self.imageID = imageID
            self.imageNumber = imageNumber
        }
    }

    /// VT bytes to replay.
    public var vt: Data
    /// Byte offset in `vt` where Ghostty stops replaying under the replay
    /// image-id cursors and applies the aliases and `nextCursors`.
    public var cursorOffset: UInt32
    public var limits: Limits
    /// Image-id cursors. Every value must be nonzero or the restore fails.
    public var replayCursors: Cursors
    public var nextCursors: Cursors
    /// At most 65,536 entries (the daemon's limit).
    public var aliases: [Alias]

    public init(
        vt: Data,
        cursorOffset: UInt32,
        limits: Limits,
        replayCursors: Cursors,
        nextCursors: Cursors,
        aliases: [Alias]
    ) {
        self.vt = vt
        self.cursorOffset = cursorOffset
        self.limits = limits
        self.replayCursors = replayCursors
        self.nextCursors = nextCursors
        self.aliases = aliases
    }
}
