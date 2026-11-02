/// New workspaces windows asked for before the daemon reported them (the app's
/// `WindowManager.claims`): reconcile places each in its window (opening the
/// window when it is not registered yet) and selects it there. A window with a
/// claim waits for that workspace: a selection repair keeps the new or empty
/// room it entered for it (#31502).
public struct WorkspaceClaims: Sendable {
    /// Workspace id -> the window that asked for it. A create claims at the
    /// press, before its window's create lane runs it.
    public var pending: [String: String] = [:]
    /// Pending claims not to show on arrival.
    public var quiet: Set<String> = []
    /// Pending claims from runs without view-change permission (an agent's or the
    /// CLI's create): they never open a Cloud machine nobody opened here (#28609);
    /// reconcile drops them for its workspaces.
    public var background: Set<String> = []

    public init() {}

    /// The create of workspace `id` failed, or a close cancelled it: its claim
    /// goes, unless the workspace `listed` (reconcile placed it, or holds it for
    /// its claim). Returns whether a window waited for it; that window then
    /// repairs its selection, so it never waits in an empty room for a
    /// workspace that will not come.
    public mutating func release(failed id: String, listed: Bool) -> Bool {
        guard !listed, pending.removeValue(forKey: id) != nil else { return false }
        quiet.remove(id)
        background.remove(id)
        return true
    }
}
