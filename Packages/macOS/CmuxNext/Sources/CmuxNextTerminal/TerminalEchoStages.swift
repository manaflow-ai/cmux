import CmuxNextWakeups

/// The process's terminal echo stages: the contents gate every terminal layer's hook reads and the
/// sink the app installs at its composition root, before its first terminal. Surfaces made before
/// the install, or with none, have no stage and cost nothing.
public final class TerminalEchoStages {
    /// Read by every terminal layer's `setContents:` hook.
    public let contentsGate = TerminalContentsGate()
    private var sink: (any TerminalEchoLatencySink)?

    public init() {}

    /// Sends every later surface's echo stages to `sink`.
    public func install(_ sink: any TerminalEchoLatencySink) {
        self.sink = sink
    }

    /// A new surface's stage, or nil while no sink is installed.
    func makeStage() -> TerminalEchoStage? {
        guard let sink else { return nil }
        return TerminalEchoStage(sink: sink, gate: contentsGate,
                                 deadline: DemandEchoDeadline(timer: DemandTimer(owner: "terminal.echo-deadline")))
    }
}
