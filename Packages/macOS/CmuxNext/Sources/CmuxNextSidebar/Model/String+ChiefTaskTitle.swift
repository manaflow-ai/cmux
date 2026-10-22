import Foundation

/// The Chief's subagent workspaces read like any other workspace (Leo 2026-10-21): their rows,
/// cards and tab titles show the task title, never the `a14` subagent id the Chief refers to
/// them by, and no "Chief" second line; who started one is in its hover card and its menu.
public nonisolated extension String {
    /// This workspace name without the `a345 · ` subagent id a Chief before 2026-10-21 put in
    /// front of its subagents' workspace names (optchat-chief `workspaces.rs`); nil when nothing
    /// is left.
    var chiefTaskTitle: String? {
        // Only the leading blanks go first: "a3 · " keeps the " · " that marks its id.
        var rest = drop(while: \.isWhitespace)
        if let dot = rest.range(of: " · "), rest.first == "a",
           rest.distance(from: rest.startIndex, to: dot.lowerBound) > 1,
           rest[rest.index(after: rest.startIndex)..<dot.lowerBound].allSatisfy(\.isNumber) {
            rest = rest[dot.upperBound...]
        }
        let trimmed = rest.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public extension MachineID {
    /// Who started a workspace on this machine, as its hover card and right-click menu say it:
    /// "Started by Chief" on the local Chief, nil elsewhere.
    @MainActor var startedBy: String? { isLocalChief ? Strings.startedByChief : nil }
}

public nonisolated extension MachineID {
    /// Whether this is the Chief owner daemon on this Mac (`ServerReach.localChief`, whose
    /// machine id is `server-host_chief<home id>`): the machine that holds the Chief's
    /// subagent workspaces.
    var isLocalChief: Bool { rawValue.hasPrefix(Self.localChiefPrefix) }

    /// The machine id prefix of the local Chief (`ServerReach.localChiefPrefix.host`).
    static let localChiefPrefix = "server-host_chief"
}
