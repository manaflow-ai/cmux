import CmuxNextWakeups

/// The process's terminal echo stages: the contents gate every terminal layer's hook reads and the
/// sink the app installs at its composition root (p04-input-094), before its first terminal.
/// Surfaces made before the install, or with none, have no stage and cost nothing.
public final class TerminalEchoStages {
    /// Read by every terminal layer's `setContents:` hook. A layer class's hook reads the gate it was
    /// installed with, so every set of stages in a process shares the runtime's
    /// (``GhosttyRuntime/echoStages``).
    public let contentsGate: TerminalContentsGate
    private var sink: (any TerminalEchoLatencySink)?

    /// - Parameter contentsGate: The process's gate: `GhosttyRuntime.shared.echoStages.contentsGate`
    ///   for any stages but the runtime's own.
    public init(contentsGate: TerminalContentsGate) {
        self.contentsGate = contentsGate
    }

    /// Sends every later surface's echo stages to `sink`.
    public func install(_ sink: any TerminalEchoLatencySink) {
        self.sink = sink
    }

    /// A new surface's stage, or nil while no sink is installed or the build sees no terminal frames
    /// (``TypingFrameProbe/hooksEveryLayer``).
    func makeStage() -> TerminalEchoStage? {
        guard TypingFrameProbe.hooksEveryLayer, let sink else { return nil }
        return TerminalEchoStage(sink: sink, gate: contentsGate,
                                 deadline: DemandEchoDeadline(timer: DemandTimer(owner: "terminal.echo-deadline")))
    }
}
