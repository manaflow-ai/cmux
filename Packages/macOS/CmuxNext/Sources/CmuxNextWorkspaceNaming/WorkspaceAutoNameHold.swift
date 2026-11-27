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
/// The held names live in Rust (`cmux-workspace-naming` `hold`), under this hold's id.
@MainActor
public final class WorkspaceAutoNameHold {
    private let id: UInt64
    private let rules = WorkspaceNamingRules()

    public init() { id = rules.nextID() }

    nonisolated deinit { rules.send("hold_drop", HoldRequest(hold: id)) }

    /// The name a row shows: `label` when its namer gives one (held from now
    /// on), else the name the same namer gave last, else nil.
    func settle(workspace: String, namer: String, label: String?) -> String? {
        rules.string("hold_settle", HoldRequest(hold: id, workspace: workspace, namer: namer, label: label), key: "name")
    }

    /// Whether `workspace`, named `name`, is launcher-named after the agent of `session`: `matches` (its name is
    /// one the agent has had) now, or it matched before under the same name and chat. Remembers a match.
    func launcherNamed(workspace: String, name: String, session: String, matches: Bool) -> Bool {
        rules.flag("hold_launcher_named", HoldRequest(hold: id, workspace: workspace, name: name, session: session, matches: matches),
                   key: "launcher_named")
    }

    /// The user named `workspace`: nothing held for it outlives that name.
    func forget(workspace: String) {
        rules.send("hold_forget", HoldRequest(hold: id, workspace: workspace))
    }

    private nonisolated struct HoldRequest: Encodable {
        var hold: UInt64
        var workspace: String?
        var namer: String?
        var label: String?
        var name: String?
        var session: String?
        var matches: Bool?
    }
}
