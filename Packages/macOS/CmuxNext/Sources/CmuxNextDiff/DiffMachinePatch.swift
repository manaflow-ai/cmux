import CmuxNextAgentPane
import CmuxNextSettings
import Foundation

/// A diff tab whose repository is on another machine (#25581, a Cloud workspace): this Mac's
/// sidecar cannot read that repository, so each open of a git source (Branch, Uncommitted,
/// Unstaged, Staged) reads the scope's `git.diff` from the machine's session host, writes it as
/// the tab's machine patch (``DiffTurnPatch/make(_:)``'s unified format) and opens that as a
/// `patch` session. The page keeps the source it asked for, so its scope menu and its freshness
/// check (`cmux.diff.git.fingerprint`, read from the same machine) behave as for a local tab.
nonisolated enum DiffMachinePatch {
    /// The request path of the tab's machine patch in its grant's manifest.
    static let requestPath = "/machine.patch"
    /// The sidecar's source for the machine patch.
    static let sidecarSource: JSONValue = ["kind": "patch", "path": .string(requestPath)]

    /// The session host scope of the page's `source`: Branch against `HEAD` is Uncommitted, Branch
    /// against any other base the session host's base branch (the machine picks it; the tab's
    /// base picker is not offered); nil for a patch or anything else.
    static func scope(_ source: JSONValue?) -> AgentPaneGitScope? {
        switch source?["kind"]?.stringValue {
        case "unstaged": .unstaged
        case "staged": .staged
        case "branch": source?["baseRef"]?.stringValue == "HEAD" ? .uncommitted : .branch
        default: nil
        }
    }

    /// The sidecar's `sessionOpened` with the page's own `source` in place of the machine patch.
    static func reporting(_ source: JSONValue?, in result: JSONValue) -> JSONValue {
        guard let source, case .object(var members) = result, case .object(var value)? = members["value"] else { return result }
        value["source"] = source
        members["value"] = .object(value)
        return .object(members)
    }
}
