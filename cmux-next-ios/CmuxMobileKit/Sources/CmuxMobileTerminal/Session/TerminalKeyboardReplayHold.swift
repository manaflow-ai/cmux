import Foundation

/// When the Mac's redraw of a full-screen app at fewer rows waits for the
/// keyboard to stop (design/terminal R1-1).
///
/// The keyboard's end is known at will-show, so the rows for it go to the Mac
/// then, and its redraw can arrive while the keyboard still rises. Shown then,
/// the shorter grid pinned to a composer still on its way up leaves a band of
/// background above it; the taller grid on screen stays pinned to the
/// composer, its top rows under the toolbar, until the keyboard stops.
///
/// The session's events arrive in stream order (`arrived`): the Mac's grid
/// (`.hostGrid`), then its mirror reset (`ESC c`), then the replay. The output
/// queue stops at that grid change (`holdsAt`), so bytes for the old grid (an
/// echo) still go out, and the reset's held frame is taken only when it is
/// fed. Anything that ends the redraw's purpose ends the hold at once: the
/// keyboard stopping, a link change (a disconnect, a reattach), the app
/// leaving the alternate screen, the process ending.
public struct TerminalKeyboardReplayHold: Equatable, Sendable {
    /// What the screen does when a hold ends.
    public struct Release: Equatable, Sendable {
        /// The output queue goes on (it was stopped at the grid).
        public var resume: Bool
        /// A reset arrived behind the grid: hold the frame now, before its
        /// replay is fed.
        public var takeHeldFrame: Bool

        public static let none = Release(resume: false, takeHeldFrame: false)

        public init(resume: Bool, takeHeldFrame: Bool) {
            self.resume = resume
            self.takeHeldFrame = takeHeldFrame
        }
    }

    /// Between will-show/will-hide (with an animation) and its end.
    public private(set) var keyboardMoving = false
    /// The Mac's shorter grid arrived while the keyboard moved; the queue
    /// stops when it reaches it.
    public private(set) var gridPending = false
    /// That grid's reset arrived: its held frame waits for the hold's end.
    public private(set) var resetDeferred = false
    /// The output queue is stopped at the grid.
    public private(set) var holding = false

    public init() {}

    /// The keyboard started an animated move.
    public mutating func keyboardStarted() {
        keyboardMoving = true
    }

    /// The keyboard reached its end (did-show/did-hide, a will with no
    /// animation, or the movement's deadline).
    public mutating func keyboardStopped() -> Release {
        keyboardMoving = false
        return end()
    }

    /// A session event, in stream order, as it arrives (before the output
    /// queue feeds it). `heldRows`: the rows of the grid on screen while the
    /// area holds it (`TerminalTUIGridHold`); `pageRows`: the page's rows now.
    /// Returns whether a mirror reset takes its held frame now (false: it
    /// waits for the hold's end), and the release when the event ends a hold.
    public mutating func arrived(_ event: TerminalSessionEvent, isTUI: Bool, heldRows: Int?, pageRows: Int)
        -> (takeHeldFrame: Bool, release: Release) {
        switch event {
        case .hostGrid(_, let rows):
            if isTUI, keyboardMoving, let heldRows, rows < heldRows, rows == pageRows {
                gridPending = true
            }
            return (false, .none)
        case .output(let data):
            guard data == Self.mirrorReset else { return (false, .none) }
            guard gridPending else { return (true, .none) }
            resetDeferred = true
            return (false, .none)
        case .connection, .exited, .alternateScreen(false):
            // A disconnect or a reattach (the Mac replays again), the process
            // gone, the app off the alternate screen: nothing to wait for.
            return (false, cancel())
        default:
            return (false, .none)
        }
    }

    /// The output queue's next step is a grid change (`nextIsGrid`): whether
    /// it stops there.
    public mutating func holdsAt(nextIsGrid: Bool) -> Bool {
        if holding { return true }
        guard gridPending, keyboardMoving, nextIsGrid else { return false }
        holding = true
        return true
    }

    /// The output queue took the grid change.
    public mutating func gridTaken() {
        gridPending = false
    }

    /// The hold ends now, whatever the keyboard does.
    public mutating func cancel() -> Release {
        end()
    }

    private mutating func end() -> Release {
        let release = Release(resume: holding, takeHeldFrame: resetDeferred)
        holding = false
        resetDeferred = false
        gridPending = false
        return release
    }

    /// `ESC c`: the session resets the mirror before a replay.
    public static let mirrorReset = Data("\u{1B}c".utf8)
}
