public import AppKit
import CmuxNextDesign
import Observation

/// Workspaces whose close the person asked for, until the daemon has closed
/// them (Lawrence 2026-10-17: "this needs to be instant"). A window's rows
/// and its selection leave them out from the press: the row starts its close
/// animation and the selection moves in that turn, while the daemon request
/// runs behind. A refused close lists the row again (it opens like a new row)
/// and says so in a toast. A window keeps a closing workspace when it would
/// list nothing else: a window closes with its last workspace, never empty.
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

    /// Starts the close of `id`. `listed` says whether a store still lists a
    /// workspace: the closes whose workspace is gone are forgotten here.
    public func begin(_ id: String, listed: (String) -> Bool) {
        ids = ids.filter(listed).union([id])
    }

    /// The daemon answered the close of `id`. A refusal lists the row again
    /// and shows the toast in `window`; a close that went through stays
    /// hidden while a store still lists it (`listed`), until `begin` forgets it.
    public func end(_ id: String, refused: Bool, listed: Bool, in window: NSWindow?) {
        guard refused || !listed else { return }
        ids.remove(id)
        guard refused, let window else { return }
        CmuxToastCenter.shared.show(CmuxToast(id: "workspace-close-refused", message: Strings.closeRefused), in: window)
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
