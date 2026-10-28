import CmuxNextInputCore
import CmuxNextWakeups

/// The process's terminal echo stages: the contents gate every terminal layer's hook reads and the
/// sink the app installs at its composition root, before its first terminal.
/// Surfaces made before the install, or with none, have no stage and cost nothing.
public final class TerminalEchoStages {
    /// Read by every terminal layer's `setContents:` hook. A layer class's hook reads the gate it was
    /// installed with, so every set of stages in a process shares the runtime's
    /// (``GhosttyRuntime/echoStages``).
    public let contentsGate: TerminalContentsGate
    private var sink: (any TerminalEchoLatencySink)?
    /// The Ghostty trace hook whose contents reports mark the stages' frames, and where each surface registers
    /// (the runtime's); nil: none.
    let traceHook: GhosttyTraceHook?

    /// - Parameter contentsGate: The process's gate: `GhosttyRuntime.shared.echoStages.contentsGate`
    ///   for any stages but the runtime's own.
    public convenience init(contentsGate: TerminalContentsGate) {
        self.init(contentsGate: contentsGate, traceHook: nil)
    }

    /// - Parameters:
    ///   - contentsGate: The process's gate.
    ///   - traceHook: The runtime's trace hook, which sees frames in every build.
    init(contentsGate: TerminalContentsGate, traceHook: GhosttyTraceHook?) {
        self.contentsGate = contentsGate
        self.traceHook = traceHook
    }

    /// Sends every later surface's echo stages to `sink`, and sets the trace hook so their frames are seen.
    public func install(_ sink: any TerminalEchoLatencySink) {
        self.sink = sink
        traceHook?.echoStagesInstalled()
    }

    /// The latency slot flow of the key press the app is dispatching (``InputLatencyToken/keyFlow``), or 0 while it
    /// dispatches none or no sink is installed: Ghostty's write of that key sends it to the daemon.
    var dispatchingKeyFlow: UInt64 { sink?.dispatchingKey?.keyFlow ?? 0 }

    /// Where a new surface's presented frames are marked (``SurfaceBridge/frameMarks``): the trace hook's
    /// recorder, which marks the stages, the typing probe and the new-terminal trace; nil without one.
    var frameMarks: GhosttyTraceHook.Recorder? { traceHook?.recorder }

    /// A new surface's stage, or nil while no sink is installed or the build sees no terminal frames:
    /// neither the DEBUG layer hook (``TypingFrameProbe/hooksEveryLayer``) nor a libghostty with the trace
    /// hook or presented frames (``GhosttyTraceHook/seesFrames``).
    func makeStage() -> TerminalEchoStage? {
        guard TypingFrameProbe.hooksEveryLayer || traceHook?.seesFrames == true, let sink else { return nil }
        return TerminalEchoStage(sink: sink, gate: contentsGate,
                                 deadline: DemandEchoDeadline())
    }
}
