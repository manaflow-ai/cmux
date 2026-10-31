import CmuxMobileModel
import Foundation
import Observation

extension MacScope {
    /// The Mac New Workspace targets: the chosen Mac (nil while it cannot
    /// take one, e.g. offline), else the creator's preferred or only Mac.
    public func newWorkspaceMac(available: [MacDevice], fallback: MacDevice?) -> MacDevice? {
        if let id = macID { return available.first { $0.id == id } }
        return fallback
    }
}

extension MacScope {
    /// The Mac the phone links while the list shows this scope. The phone
    /// links one Mac at a time, and a Mac the user chose to look at must
    /// never sit unlinked behind a false empty state (verify/e2e-matrix.md
    /// #2): the chosen Mac when it is online. Nil for All Macs (the link
    /// keeps its Mac) and for an offline or unknown Mac (nothing to dial).
    public func macToLink(in macs: [MacDevice]) -> String? {
        guard let id = macID, macs.contains(where: { $0.id == id && $0.isOnline }) else { return nil }
        return id
    }

    /// Opening a workspace links its Mac when it is online.
    public static func macToLink(opening workspace: Workspace, in macs: [MacDevice]) -> String? {
        MacScope.mac(workspace.macID).macToLink(in: macs)
    }
}

/// Live mode: moves the phone's one link to a Mac.
public struct MacLinking {
    /// Links the Mac (nothing when it already is the link's Mac).
    public var link: @MainActor (String) -> Void
    /// Whether this phone may dial the Mac at all (a teammate's Mac in a
    /// shared team is listed, never dialed). A read, safe in a view body.
    public var canLink: @MainActor (String) -> Bool
    /// Whether the phone's one link targets the Mac now (dialing or up). A read.
    public var isLinkTarget: @MainActor (String) -> Bool

    public init(link: @escaping @MainActor (String) -> Void, canLink: @escaping @MainActor (String) -> Bool,
                isLinkTarget: @escaping @MainActor (String) -> Bool) {
        self.link = link
        self.canLink = canLink
        self.isLinkTarget = isLinkTarget
    }

    /// How the link stands toward `macID`, for ``MacEmptyState``.
    @MainActor public func reach(_ macID: String) -> MacReach {
        guard canLink(macID) else { return .othersMac }
        return isLinkTarget(macID) ? .linkTarget : .elsewhere
    }
}

/// How the phone's link stands toward one Mac.
public enum MacReach: Equatable, Sendable {
    /// No live link to move (mock mode).
    case none
    /// The link targets this Mac: its data is on its way.
    case linkTarget
    /// The link is on another Mac (or none); Connect moves it here.
    case elsewhere
    /// A teammate's Mac: protocol v1 lets only its owner's phones connect.
    case othersMac
}

/// What the list says when it is filtered to one Mac and has no rows.
public enum MacEmptyState: Equatable, Sendable {
    case offline
    case failed(String)
    /// Online, and the link is not on it: Connect moves it here.
    case notConnected
    /// A teammate's Mac: listed, but only its owner's phones can connect.
    case othersMac
    /// Online and being linked: its list (or the ability to create on it)
    /// arrives with the link.
    case connecting
    /// The Mac answered with no workspaces (or cached data says so).
    case empty(canCreate: Bool)

    /// - `reach`: how the phone's link stands toward the Mac. "Connecting"
    ///   only while the link actually targets it; otherwise Connect.
    /// - `connection`: this phone's link to the Mac (nil: not linked).
    /// - `tracksLive`: live data (false in mock mode, where every list is the Mac's).
    public static func resolve(isOnline: Bool, list: WorkspaceInbox.ListState, connection: MacConnection?,
                               tracksLive: Bool, reach: MacReach, canCreate: Bool) -> MacEmptyState {
        guard isOnline else { return .offline }
        if reach == .othersMac { return .othersMac }
        let autoLinks = reach == .linkTarget
        switch list {
        case .failed(let reason):
            return .failed(reason)
        case .notConnected:
            return autoLinks ? .connecting : .notConnected
        case .loading:
            return reach == .elsewhere ? .notConnected : .connecting
        case .live, .cached:
            if canCreate || !tracksLive { return .empty(canCreate: canCreate) }
            switch connection {
            case .failed(let reason): return .failed(reason)
            // Linked, but the Mac's own list has not come over this link
            // yet (the rows are last-known): still connecting. Only a Mac
            // that answered and still refuses new workspaces says so.
            case .connected: return list == .live ? .empty(canCreate: false) : .connecting
            case .connecting: return autoLinks || reach == .none ? .connecting : .notConnected
            case nil: return autoLinks ? .connecting : .notConnected
            }
        }
    }
}
