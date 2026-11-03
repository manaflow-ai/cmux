/// The pane a person's Close Tab press is aimed at, after a close emptied a pane and the focus
/// moved to another one (Leo 2026-10-21; Lawrence 2026-10-23). Kept per window by its
/// focus coordinator (`FocusCoordinator` in the app).
///
/// A press is aimed at what the person saw when they pressed. The close of a pane's last tab moves
/// the focus to a pane the person did not pick, so:
/// - a press made before the frame that shows the focus in the new pane was presented (queued
///   behind the emptying press, or typed in the same refresh) is aimed at the emptied pane;
/// - a key repeat is the same press as the key-down it repeats: a repeat of the key that emptied
///   the pane, or of a press aimed at it, is aimed at it too;
/// - a fresh press made after that frame was presented closes in the pane now focused, at once.
///
/// A press aimed at the emptied pane closes nothing there and nothing elsewhere; the caller shows
/// why (the refusal HUD), so no press is silent. No time window: only the presented frame and the
/// key's own repeat flag decide.
///
/// ```swift
/// var aim = PaneCloseAim()
/// aim.paneEmptied("right", by: .init(time: 10, isKey: true, isRepeat: false))
/// let move = aim.paneMoved(from: "right", to: "left")
/// aim.presented(move, at: 10.02)
/// aim.aimsAtEmptiedPane(.init(time: 10.01, isKey: true, isRepeat: false), focused: "left") // true
/// aim.aimsAtEmptiedPane(.init(time: 10.30, isKey: true, isRepeat: false), focused: "left") // false
/// ```
public nonisolated struct PaneCloseAim: Equatable, Sendable {
    /// The last move of the window's focused pane.
    public struct Move: Equatable, Sendable {
        /// The pane the focus left, or nil when no pane had it.
        public var from: String?
        /// The pane the focus moved to, or nil when no pane has it now.
        public var to: String?
        /// Identifies the move, so a late presentation stamp never lands on a newer move.
        public var serial: UInt64
        /// When the frame that shows this move was presented (seconds of system uptime, the clock
        /// of `NSEvent.timestamp`); nil until its commit.
        public var presentedAt: Double?
    }

    /// One Close Tab press.
    public struct Press: Equatable, Sendable {
        /// When the person made it (seconds of system uptime).
        public var time: Double
        /// A key-down: a held key may repeat it.
        public var isKey: Bool
        /// An auto-repeat of a held key (`NSEvent.isARepeat`).
        public var isRepeat: Bool

        /// A press made at `time`.
        ///
        /// - Parameter time: When the person made it (seconds of system uptime).
        /// - Parameter isKey: Whether it is a key-down (a click or a menu run is not).
        /// - Parameter isRepeat: Whether it is an auto-repeat of a held key.
        public init(time: Double, isKey: Bool, isRepeat: Bool) {
            self.time = time
            self.isKey = isKey
            self.isRepeat = isRepeat
        }
    }

    /// The last move of the window's focused pane, or nil before the first.
    public private(set) var move: Move?
    /// The pane the last press emptied while the focus has not been seen elsewhere yet.
    public private(set) var emptied: String?
    /// The held key's press was aimed at ``emptied`` (the key that emptied it, or a later press
    /// aimed at it): its repeats are aimed there too. A fresh key-down decides again.
    private var held = false
    private var serial: UInt64 = 0

    /// No pane emptied and no move seen.
    public init() {}

    /// The focused pane moved from `from` to `to`.
    ///
    /// - Parameter from: The pane the focus left.
    /// - Parameter to: The pane the focus moved to.
    /// - Returns: The move's serial, for ``presented(_:at:)``.
    public mutating func paneMoved(from: String?, to: String?) -> UInt64 {
        serial &+= 1
        move = Move(from: from, to: to, serial: serial, presentedAt: nil)
        return serial
    }

    /// The frame that shows move `serial` was presented at `time`; a stamp for an older move, or a
    /// second stamp, changes nothing.
    ///
    /// - Parameter serial: The move's serial from ``paneMoved(from:to:)``.
    /// - Parameter time: The presentation time (seconds of system uptime).
    public mutating func presented(_ serial: UInt64, at time: Double) {
        guard move?.serial == serial, move?.presentedAt == nil else { return }
        move?.presentedAt = time
    }

    /// `press` closed the last tab of `pane`.
    ///
    /// - Parameter pane: The emptied pane.
    /// - Parameter press: The press that emptied it (a held key's repeats are aimed at the pane).
    public mutating func paneEmptied(_ pane: String, by press: Press) {
        emptied = pane
        held = press.isKey
    }

    /// Whether `press` is aimed at the emptied pane (it closes nothing) rather than at `focused`.
    ///
    /// - Parameter press: The Close Tab press.
    /// - Parameter focused: The pane the focus model has now.
    /// - Returns: True when the press closes nothing and the caller shows why.
    public mutating func aimsAtEmptiedPane(_ press: Press, focused: String?) -> Bool {
        guard let pane = emptied else { return false }
        if press.isRepeat {
            if held { return true }
        } else if press.isKey {
            held = false
        }
        // The focus has not left the emptied pane yet: the press acts on it as on any pane.
        guard focused != pane else { return false }
        // The person moved the focus since (a click, a pane key): the press is theirs to aim.
        guard let move, move.from == pane, move.to == focused else {
            emptied = nil
            return false
        }
        guard let shown = move.presentedAt, press.time >= shown else {
            // Held, this key's repeats are the same press, aimed at the emptied pane too.
            held = press.isKey
            return true
        }
        emptied = nil
        return false
    }
}
