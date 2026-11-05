public import CmuxNextDaemon

/// Which acpmux an agent tab's pane attaches to.
public enum AgentPaneHostKind: Equatable, Sendable {
    /// This Mac's own acpmux (the app's chats).
    case local
    /// This app's Chief home's acpmux, where the Chief host runs its subagents.
    case chief
    /// Another machine's, through that tab's session daemon.
    case remote

    /// The acpmux that runs `record`'s session: the record says who owns it, so a restored tab
    /// attaches to the same daemon.
    ///
    /// - Parameters:
    ///   - listedHere: whether this Mac's own tree lists the tab. Every `chief:<home id>`
    ///     such a tab names is a Chief home of this Mac (#25262): the record keeps the home it was
    ///     made under (NIGHTLY's per-build home before it moved to the shared one, a tagged build's
    ///     home), so it may differ from `chiefHost` and is still never another machine's.
    ///   - formerLocalHosts: this Mac's other `install:<id>` hosts (its other Cloud backends' ids,
    ///     #35284): a tab this Mac's tree lists under one is this Mac's. Read only when the record
    ///     names none of the hosts above.
    public init(_ record: AgentSessionRef, localHost: String?, chiefHost: String?, listedHere: Bool,
                formerLocalHosts: @autoclosure () -> Set<String> = []) {
        if let localHost, record.host == localHost {
            self = .local
        } else if let chiefHost, record.host == chiefHost {
            self = .chief
        } else if listedHere, record.host.hasPrefix(ChiefHome.tabHostPrefix) {
            self = .chief
        } else if listedHere, localHost != nil, formerLocalHosts().contains(record.host) {
            self = .local
        } else {
            self = .remote
        }
    }
}
