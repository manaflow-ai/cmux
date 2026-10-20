/// The last name each sidebar row took from its front tab (hq#1957), so a row
/// keeps it while that same tab's name is briefly unknown. A chat's title
/// lives in the turn store, which knows nothing between a relaunch or a watch
/// reconnect and its first page; without this every chat-named row read
/// `workspace-N` in that gap, all at once.
///
/// Only the tab that gave the name holds it: another front tab (a terminal,
/// a New Tab page) names the row afresh, and a name the user gave wins before
/// this is asked (`WorkspaceAutoNameReader.label`). Not observable: rows map
/// under observation and must not write what they observe; a row maps again
/// when its tab's name comes back, which is all a held name waits for.
@MainActor
public final class WorkspaceAutoNameHold {
    /// The app's: every reader of `AgentTurnStateStore.shared` holds names here.
    public static let shared = WorkspaceAutoNameHold()

    /// By workspace id: the tab (and work tab) that named the row, and its name.
    private var held: [String: (namer: String, name: String)] = [:]

    public init() {}

    /// The name a row shows: `label` when its front tab gives one (it is held
    /// from now on), else the name the same `namer` gave last, else nil.
    func settle(workspace: String, namer: String, label: String?) -> String? {
        if let label {
            if held[workspace]?.namer != namer || held[workspace]?.name != label { held[workspace] = (namer, label) }
            return label
        }
        guard let last = held[workspace], last.namer == namer else { return nil }
        return last.name
    }
}
