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
    /// this session, its output lane and what its frames go to (``traceFrameTarget(of:)``).
    /// Nothing in Release: there the content cache marks `surface_created` (``traceCreate(_:surface:)``).
    func traceSurfaceCreated(io: any TerminalIO) {
        #if DEBUG || CMUX_BENCH_HOOKS
        guard NewTerminalTrace.shared.isArmed else { return }
        _ = NewTerminalTrace.shared.sessionCreated(io: ObjectIdentifier(io as AnyObject), session: ObjectIdentifier(self),
                                                   lane: surfaceView.lane.map { ObjectIdentifier($0) },
                                                   layer: Self.traceFrameTarget(of: surfaceView))
        #endif
    }
}

#if DEBUG || CMUX_BENCH_HOOKS
// DEBUG builds: called only while a trace is armed.
extension TerminalSession {
    /// What the trace's `contents` marks name for `view`'s frames: its layer, whose `setContents:` gets each frame
    /// (``TypingFrameProbe``), or with renderer-owned frames the trace hook's state of its surface, which each
    /// presented frame marks (``ghosttySurfacePresented(_:_:_:_:)``).
    static func traceFrameTarget(of view: TerminalSurfaceView) -> ObjectIdentifier? {
        #if GHOSTTY_RENDERER_FRAMES
        ObjectIdentifier(view.bridgeObject.frames)
        #else
        view.layer.map { ObjectIdentifier($0) }
        #endif
    }

    /// A later replay swapped in `fresh`: watch its lane and frames instead.
    func traceSurfaceSwapped(_ fresh: TerminalSurfaceView) {
        NewTerminalTrace.shared.surfaceSwapped(session: ObjectIdentifier(self), lane: fresh.lane.map { ObjectIdentifier($0) },
                                               layer: Self.traceFrameTarget(of: fresh))
    }
}
#endif
