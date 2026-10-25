#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextWakeups

// DEBUG builds: this session's part of a `debug.new_terminal_trace` run
// (``NewTerminalTrace``). Called only while a trace is armed.
extension TerminalSession {
    /// The session over `io` created its surface: when `io` is the traced terminal's,
    /// watch this session, its output lane and its layer (`setContents:` marks).
    func traceSurfaceCreated(io: any TerminalIO) {
        guard NewTerminalTrace.shared.sessionCreated(io: ObjectIdentifier(io as AnyObject), session: ObjectIdentifier(self),
                                                     lane: surfaceView.lane.map { ObjectIdentifier($0) },
                                                     layer: surfaceView.layer.map { ObjectIdentifier($0) }) else { return }
        if let layer = surfaceView.layer { TypingFrameProbe.install(on: layer) }
    }

    /// A later replay swapped in `fresh`: watch its lane and layer instead.
    func traceSurfaceSwapped(_ fresh: TerminalSurfaceView) {
        NewTerminalTrace.shared.surfaceSwapped(session: ObjectIdentifier(self), lane: fresh.lane.map { ObjectIdentifier($0) },
                                               layer: fresh.layer.map { ObjectIdentifier($0) })
        if let layer = fresh.layer { TypingFrameProbe.install(on: layer) }
    }

    /// `event` reached this session on the main actor; content marks `first_output_main`.
    func traceEvent(_ event: TerminalIOEvent) {
        switch event {
        case .replay(let data) where data.isEmpty: return
        case .replay, .kittyReplay, .snapshot, .output: NewTerminalTrace.shared.contentOnMain(session: ObjectIdentifier(self))
        default: return
        }
    }
}
#endif
