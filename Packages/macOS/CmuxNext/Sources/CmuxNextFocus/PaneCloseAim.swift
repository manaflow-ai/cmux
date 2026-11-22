/// The pane a person's Close Tab press is aimed at, after a close emptied a pane and the focus
/// moved to another one (Leo 2026-10-21; Lawrence 2026-10-23). The rule and its state are
/// cmux-focus-core's (`close_aim::PaneCloseAim`), kept by the window's focus machine; this forwards
/// the window's calls to it (`FocusCoordinator` in the app).
///
/// A press made before the frame that shows the focus in the new pane was presented, or a repeat
/// of the key that emptied the pane, is aimed at the emptied pane: it closes nothing, and the
/// caller shows why (the refusal HUD). A fresh press after that frame closes in the pane now
/// focused. No time window: only the presented frame and the key's own repeat flag decide.
///
/// ```swift
/// let aim = PaneCloseAim(machine: machine)
/// aim.paneEmptied("right", by: .init(time: 10, isKey: true, isRepeat: false))
/// let move = aim.paneMoved(from: "right") // the machine now focuses "left"
/// aim.presented(move, at: 10.02)
/// aim.aimsAtEmptiedPane(.init(time: 10.01, isKey: true, isRepeat: false)) // true
/// aim.aimsAtEmptiedPane(.init(time: 10.30, isKey: true, isRepeat: false)) // false
/// ```
public nonisolated struct PaneCloseAim {
    /// One Close Tab press.
    public struct Press: Equatable, Sendable {
        /// When the person made it (seconds of system uptime, the clock of `NSEvent.timestamp`).
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

    private let machine: FocusMachine

    /// The aim kept by `machine`, the window's focus machine.
    public init(machine: FocusMachine) {
        self.machine = machine
    }

    /// The focused pane moved from `from` to the pane the machine focuses now.
    ///
    /// - Parameter from: The pane the focus left.
    /// - Returns: The move's serial, for ``presented(_:at:)``.
    public func paneMoved(from: String?) -> UInt64 {
        machine.paneMoved(from: from)
    }

    /// The frame that shows move `serial` was presented at `time`; a stamp for an older move, or a
    /// second stamp, changes nothing.
    public func presented(_ serial: UInt64, at time: Double) {
        machine.framePresented(serial, at: time)
    }

    /// `press` closed the last tab of `pane` (a held key's repeats are aimed at the pane).
    public func paneEmptied(_ pane: String, by press: Press) {
        machine.paneEmptied(pane, by: press)
    }

    /// Whether `press` is aimed at the emptied pane (it closes nothing and the caller shows why)
    /// rather than at the pane the machine focuses now.
    public func aimsAtEmptiedPane(_ press: Press) -> Bool {
        machine.aimsAtEmptiedPane(press)
    }
}
