/// The last name each tab gave the sidebar row of its workspace (hq#1957), so
/// a row keeps it while that same tab's name is briefly unknown. A chat's
/// title lives in the turn store, which knows nothing between a relaunch or a
/// watch reconnect and its first page; without this every chat-named row read
/// `workspace-N` in that gap, all at once.
///
/// Held per tab and the chat it shows: a tab that never named the row (a New
/// Tab page, a new chat in the same tab) names it afresh, and a name the user
/// gave wins before this is asked (`WorkspaceAutoNameReader.label`). Not
/// observable: rows map under observation and must not write what they
/// observe; a row maps again when its tab's name comes back, which is all a
/// held name waits for. The app owns one (`AppServices.autoNameHold`).
@MainActor
public final class WorkspaceAutoNameHold {
    /// By workspace id, then by namer (`WorkspaceAutoNameReader.namer`): the name it gave last.
    private var held: [String: [String: String]] = [:]
    /// By workspace id: the launch name and chat of a workspace its launcher named after that chat's agent. acpmux
    /// keeps only a few `formerNames` and drops one another session takes, so after enough renames the launch name
    /// is no longer among them; this keeps the workspace following its agent anyway.
    private var launcherNamed: [String: String] = [:]

    public init() {}

    /// The name a row shows: `label` when its namer gives one (held from now
    /// on), else the name the same namer gave last, else nil.
    func settle(workspace: String, namer: String, label: String?) -> String? {
        guard let label else { return held[workspace]?[namer] }
        if held[workspace]?[namer] != label { held[workspace, default: [:]][namer] = label }
        return label
    }

    /// Whether `workspace`, named `name`, is launcher-named after the agent of `session`: `matches` (its name is
    /// one the agent has had) now, or it matched before under the same name and chat. Remembers a match.
    func launcherNamed(workspace: String, name: String, session: String, matches: Bool) -> Bool {
        let key = session + "\u{0}" + name
        if matches {
            if launcherNamed[workspace] != key { launcherNamed[workspace] = key }
            return true
        }
        return launcherNamed[workspace] == key
    }

    /// The user named `workspace`: nothing held for it outlives that name.
    func forget(workspace: String) {
        if held[workspace] != nil { held[workspace] = nil }
    }
}
