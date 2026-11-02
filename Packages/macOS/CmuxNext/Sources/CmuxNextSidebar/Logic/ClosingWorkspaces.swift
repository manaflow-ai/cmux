public import AppKit
import CmuxNextDesign
import Observation

/// Workspaces whose close the person asked for, until the daemon has closed
/// them (Lawrence 2026-10-17: "this needs to be instant"). A window's rows
/// and its selection leave them out from the press: the row starts its close
/// animation and the selection moves in that turn, while the daemon request
/// runs behind. A refused close lists the row again (it opens like a new row)
/// and says so in a toast. A close that would leave its window's room with no
/// other row is not hidden: a window closes with its last workspace, never empty.
@MainActor @Observable
public final class ClosingWorkspaces {
    public static let shared = ClosingWorkspaces()

    public private(set) var ids: Set<String> = []

    /// Proof hook (`debug.sidebar_rows {"refuse_next_close": true}`): the next close fails before it reaches the daemon.
    @ObservationIgnored public var refusesNext = false

    public init() {}

    /// Throws once after `refusesNext` was set (the close then takes the refusal path).
    public func refusal() throws {
        guard refusesNext else { return }
        refusesNext = false
        throw ClosingWorkspacesRefusal()
    }

    /// Starts the close of `id`, one of `members` (its window's rows in the room it shows). False, and nothing
    /// hidden, when no other member would be left.
    public func begin(_ id: String, among members: [String]) -> Bool {
        guard members.contains(where: { $0 != id && !ids.contains($0) }) else { return false }
        ids.insert(id)
        return true
    }

    /// The close of `id` ended: the daemon refused it, or the store applied its result (the row is gone
    /// from the store). A refusal lists the row again and shows the toast in `window`: `reason` when the
    /// close knows why (its machine did not answer), else that it could not be closed.
    public func end(_ id: String, refused: Bool, reason: String? = nil, in window: NSWindow?) {
        ids.remove(id)
        guard refused, let window else { return }
        CmuxToastCenter.shared.show(CmuxToast(id: "workspace-close-refused", message: reason ?? Strings.closeRefused), in: window)
    }

    /// `members` without the closing workspaces, unless that leaves none.
    public func survivors(_ members: [String]) -> [String] {
        guard !ids.isEmpty else { return members }
        let left = members.filter { !ids.contains($0) }
        return left.isEmpty ? members : left
    }
}

/// The debug refusal of `ClosingWorkspaces.refusal()`.
public struct ClosingWorkspacesRefusal: Error, CustomStringConvertible {
    public var description: String { "close refused (debug.sidebar_rows refuse_next_close)" }
}
