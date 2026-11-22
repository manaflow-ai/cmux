import CCmuxLayoutReducerFFI

/// The machine's Close Tab aim (``PaneCloseAim``): which pane a close key typed after a close aims at.
extension FocusMachine {
    /// The focused pane moved from `from` to the machine's focused pane; returns the move's serial.
    func paneMoved(from: String?) -> UInt64 {
        guard let from else { return call { cmux_input_focus_pane_moved($0, $1, $2, nil, 0, 0) } }
        return Array(from.utf8).withUnsafeBufferPointer { pane in call { cmux_input_focus_pane_moved($0, $1, $2, pane.baseAddress, pane.count, 1) } }
    }

    /// The frame that shows move `serial` was presented at `time` (seconds of system uptime).
    func framePresented(_ serial: UInt64, at time: Double) {
        call { cmux_input_focus_frame_presented($0, $1, $2, serial, time) }
    }

    /// `press` closed the last tab of `pane`.
    func paneEmptied(_ pane: String, by press: PaneCloseAim.Press) {
        Array(pane.utf8).withUnsafeBufferPointer { pane in
            call { cmux_input_focus_pane_emptied($0, $1, $2, pane.baseAddress, pane.count, press.time, press.isKey ? 1 : 0, press.isRepeat ? 1 : 0) }
        }
    }

    /// Whether `press` is aimed at a pane a close emptied, not at the machine's focused pane.
    func aimsAtEmptiedPane(_ press: PaneCloseAim.Press) -> Bool {
        call { cmux_input_focus_aims_at_emptied_pane($0, $1, $2, press.time, press.isKey ? 1 : 0, press.isRepeat ? 1 : 0) } != 0
    }
}
