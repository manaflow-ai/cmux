public import Foundation

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

    /// True when the owner keeps its own VT state and answers terminal
    /// queries (DA, DSR, OSC color queries). The cmux-tui daemon does, so the
    /// surface runs in `GHOSTTY_SURFACE_IO_MANUAL_MIRROR` and Ghostty's parser
    /// replies are suppressed. A bare PTY does not, so the surface runs in
    /// `GHOSTTY_SURFACE_IO_MANUAL` and Ghostty replies (ghostty.h:552-559).
    var answersTerminalQueries: Bool { get }

    /// The surface gained keyboard focus. Ordered with `write` and `resize`.
    /// A daemon IO takes canonical geometry back if another client took it
    /// (the latest active client holds geometry).
    func focusGained() async

    /// The user clicked a disconnected terminal (``TerminalConnectionStatus``).
    /// A daemon IO re-attaches. Ordered with `write`.
    func reconnectRequested() async
}

public extension TerminalIO {
    var answersTerminalQueries: Bool { true }
    func focusGained() async {}
    func reconnectRequested() async {}
}

/// One event from a ``TerminalIO``.
public nonisolated enum TerminalIOEvent: Sendable, Equatable {
    /// Full screen state to restore (a VT replay). The first replay goes into
    /// the fresh surface; a later one (reattach, daemon-side reflow) causes the
    /// session to swap in a new surface, because Ghostty has no reset API
    /// (cmux-tui-contract.md 3.2).
    case replay(Data)
    /// Replay that also carries Kitty graphics state. Applied with
    /// `ghostty_surface_restore_kitty_replay` on a fresh surface.
    case kittyReplay(TerminalKittyReplay)
    /// Live PTY output, fed to `ghostty_surface_process_output`.
    case output(Data)
    /// The PTY's grid from this point in the stream (the daemon applied a
    /// size). Always applied with `ghostty_surface_set_grid_size`; after the
    /// first one the surface renders only these grids. Send one for every
    /// size the PTY takes, including the initial one.
    case resize(cols: Int, rows: Int)
    /// The terminal's process exited. The surface stays readable.
    case exited
    /// The view's link to its terminal changed; the last screen stays.
    case status(TerminalConnectionStatus)
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
    /// At most 65,536 entries (ghostty.h `ghostty_surface_restore_kitty_replay`).
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
