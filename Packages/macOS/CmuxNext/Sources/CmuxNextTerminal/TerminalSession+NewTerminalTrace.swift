import AppKit
public import CmuxNextSignposts
import CmuxNextWakeups

// This session's stages of a new terminal (``NewTerminalTrace``): `create.tab` instants, in every build, while the
// new tab it shows waits for its first frame and, in DEBUG, its part of a `debug.new_terminal_trace` run.
extension TerminalSession {
    /// This session shows the new terminal tab whose open interval is `create` (on daemon surface `surface`): its
    /// `surface_created` stage now, and its later stages (a layout spring's final grid) while `create` stays open.
    /// The content cache calls it for each view it makes; nil (a restored, reattached or remade view) marks nothing.
    public func traceCreate(_ create: CreateTabInterval?, surface: UInt64) {
        guard let create else { return }
        createStages = NewTerminalTrace.CreateStages(create)
        createStages.event(.surfaceCreated, value: surface)
    }

    /// The session over `io` created its surface: while a trace is armed and `io` is the traced terminal's, watch
    /// this session, its output lane and its layer (`setContents:` marks; every terminal layer has the hook,
    /// ``TypingFrameProbe``). Nothing in Release: there the content cache marks `surface_created` (``traceCreate(_:surface:)``).
    func traceSurfaceCreated(io: any TerminalIO) {
        #if DEBUG || CMUX_BENCH_HOOKS
        guard NewTerminalTrace.shared.isArmed else { return }
        _ = NewTerminalTrace.shared.sessionCreated(io: ObjectIdentifier(io as AnyObject), session: ObjectIdentifier(self),
                                                   lane: surfaceView.lane.map { ObjectIdentifier($0) },
                                                   layer: surfaceView.layer.map { ObjectIdentifier($0) })
        #endif
    }
}

#if DEBUG || CMUX_BENCH_HOOKS
// DEBUG builds: called only while a trace is armed.
extension TerminalSession {
    /// A later replay swapped in `fresh`: watch its lane and layer instead.
    func traceSurfaceSwapped(_ fresh: TerminalSurfaceView) {
        NewTerminalTrace.shared.surfaceSwapped(session: ObjectIdentifier(self), lane: fresh.lane.map { ObjectIdentifier($0) },
                                               layer: fresh.layer.map { ObjectIdentifier($0) })
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
