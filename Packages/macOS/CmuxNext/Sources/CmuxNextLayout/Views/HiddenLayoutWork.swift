/// Work that reached workspaces while they were off screen, for the whole app (`debug.layout_counters`
/// `hidden_workspace_layouts` and `hidden_workspace_applies`; bench_idle.py, p06-scheduler.md done checks 4 and 6).
/// The composition root owns one and hands it to every workspace's root, so the counts only grow: a workspace that
/// unmounts inside a bench window keeps its share in them.
@MainActor
public final class HiddenLayoutWork {
    /// Layout passes of a root while its workspace was off screen. A hidden workspace's changes update the model
    /// only, so a pass here is work nobody sees.
    public private(set) var layoutPasses: UInt64 = 0
    /// Tree changes that reached an off-screen workspace: each updated the handles only and waited for the show.
    public private(set) var applies: UInt64 = 0

    public init() {}

    public func noteLayoutPass() { layoutPasses &+= 1 }

    public func noteApply() { applies &+= 1 }

    /// `debug.layout_counters` `reset`.
    public func reset() {
        layoutPasses = 0
        applies = 0
    }
}
