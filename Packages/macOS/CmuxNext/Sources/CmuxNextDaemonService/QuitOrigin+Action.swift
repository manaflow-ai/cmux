public import CmuxNextActions

/// A quit request that names more than one choice.
public struct QuitArgumentConflict: Error, Equatable {
    public init() {}
    public static let reason = "quit takes one of --keep-sessions, --end-sessions and --end-everything"
}

extension QuitOrigin {
    /// The origin of a `quit` action run: its flags, else scripted for a
    /// capturing caller (control socket, CLI), else interactive.
    public init(for invocation: ActionInvocation, scripted: Bool) throws(QuitArgumentConflict) {
        let flags: [(String, QuitSessionsChoice)] = [("keepSessions", .keep), ("endSessions", .endKeepLayout), ("endEverything", .endEverything)]
        let chosen = flags.filter { invocation[$0.0]?.boolValue == true }.map(\.1)
        guard chosen.count <= 1 else { throw QuitArgumentConflict() }
        self = chosen.first.map { QuitOrigin.explicit($0) } ?? (scripted ? .scripted : .interactive)
    }
}
