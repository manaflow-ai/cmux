public import Foundation

/// Team Cloud session links (cloud multiplayer, contract C5): a Cloud chat or workspace of a team,
/// `cmux://cloud/session/<team>/<vm>/<session>` and `cmux://cloud/workspace/<team>/<vm>/<workspace>`.
/// The record lives in the team's TeamDO (backend team-cloud-session-ops.ts), so the link means the
/// same thing for every member of the team on every Mac; a person outside the team is refused.
nonisolated extension DeepLink {
    /// Which half of a team Cloud link: a chat (`cloud/session/…`) or a workspace (`cloud/workspace/…`).
    public enum CloudSessionKind: String, Sendable, Hashable, CaseIterable {
        case chat = "session"
        case workspace

        /// The backend's `kind` (`chat` or `workspace`).
        public var wireKind: String { self == .chat ? "chat" : "workspace" }

        public init?(wireKind: String) {
            switch wireKind {
            case "chat": self = .chat
            case "workspace": self = .workspace
            default: return nil
            }
        }
    }

    /// A team id as TeamDO names it: `team_` and 20 lowercase letters or digits.
    static func isTeamID(_ text: String) -> Bool {
        guard text.hasPrefix("team_") else { return false }
        let rest = text.utf8.dropFirst(5)
        return rest.count == 20 && rest.allSatisfy { (48...57).contains($0) || (97...122).contains($0) }
    }

    /// A Cloud machine id: `vm_` (or an older record's `vm-`) and 1 to 64 ASCII letters or digits
    /// (backend `CloudSessionVm`).
    public static func isCloudVM(_ text: String) -> Bool {
        guard text.hasPrefix("vm_") || text.hasPrefix("vm-") else { return false }
        let rest = text.utf8.dropFirst(3)
        return (1...64).contains(rest.count) && rest.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }
    }

    /// A chat's acpmux session id or a workspace's id on its VM (backend `CloudSessionId`): a letter or
    /// digit, then up to 127 letters, digits, `.`, `_`, `:` or `-`.
    public static func isCloudSessionID(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard let first = bytes.first, (1...128).contains(bytes.count) else { return false }
        let alnum = { (b: UInt8) in (48...57).contains(b) || (65...90).contains(b) || (97...122).contains(b) }
        return alnum(first) && bytes.allSatisfy { alnum($0) || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: ":") || $0 == UInt8(ascii: "-") }
    }

    /// `cloud/<session|workspace>/<team>/<vm>/<id>`'s target, nil for anything else.
    static func cloudTarget(_ segments: [String], fragment: String?) -> Target? {
        guard fragment == nil, segments.count == 4, let kind = CloudSessionKind(rawValue: segments[0]),
              isTeamID(segments[1]), isCloudVM(segments[2]), isCloudSessionID(segments[3]) else { return nil }
        return .cloudSession(team: segments[1], machine: segments[2], session: segments[3], kind: kind)
    }

    /// The `cloud:<team>/<vm>/<session>` key (C5) or a `cmux://cloud/…` link (any build's `cmux…`
    /// scheme: `cmux`, `cmux-dev`, `cmux-next`) as a link.
    /// The key names no kind; it reads as a chat, which the record corrects when it is read.
    ///
    /// - Parameter text: What a person or script passed (`--session`).
    /// - Returns: The link, or nil when `text` is neither.
    public static func cloudSession(_ text: String) -> DeepLink? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("cloud:") {
            let parts = trimmed.dropFirst("cloud:".count).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, isTeamID(parts[0]), isCloudVM(parts[1]), isCloudSessionID(parts[2]) else { return nil }
            return DeepLink(.cloudSession(team: parts[0], machine: parts[1], session: parts[2], kind: .chat))
        }
        guard let url = URL(string: trimmed), let scheme = url.scheme, scheme.hasPrefix("cmux"), isScheme(scheme),
              let link = parse(url, scheme: scheme), case .cloudSession = link.target else { return nil }
        return link
    }

    /// What opening a team Cloud link does, decided from `team.cloud.session.get`'s answer and what
    /// this Mac shows (the App's CloudSessionLink reads the record and shows it).
    public enum CloudSessionPlan: Equatable, Sendable {
        /// Show this workspace (its id on the VM's daemon) or this chat, open here already.
        case reveal(kind: CloudSessionKind, machine: String, session: String)
        /// The session is on a teammate's machine (or one this Mac is not connected to): attach to it
        /// through the shared relay (lane C's attach path).
        case attach(kind: CloudSessionKind, team: String, machine: String, session: String)
        /// The caller is not a member of the team (or a guest): `auth.forbidden`.
        case notMember
        /// The session was closed or removed: `cloud_session.not_found`.
        case gone
        /// The Cloud service did not answer; nothing changed, try again.
        case unreachable
        /// Signed out of cmux.
        case signedOut
    }

    /// The plan for a team Cloud link.
    ///
    /// - Parameters:
    ///   - team: The link's team.
    ///   - reply: `team.cloud.session.get`'s value (`{session: {vm, session, kind, …}}`), nil when it refused.
    ///   - errorCode: The refusal's code when the read refused (`auth.forbidden`, `cloud_session.not_found`, …),
    ///     nil for a transport failure.
    ///   - signedIn: Whether the app is signed in.
    ///   - openHere: Whether this Mac shows that session (kind, machine, id) now.
    public static func cloudSessionPlan(team: String, reply: [String: Any]?, errorCode: String?, signedIn: Bool,
                                        openHere: (CloudSessionKind, String, String) -> Bool) -> CloudSessionPlan {
        guard signedIn else { return .signedOut }
        guard let session = reply?["session"] as? [String: Any] else {
            switch errorCode {
            case "auth.forbidden", "auth.unauthenticated", "team.not_member": return .notMember
            case "cloud_session.not_found", "selector.not_found": return .gone
            default: return .unreachable
            }
        }
        guard let machine = session["vm"] as? String, let id = session["session"] as? String,
              let kind = (session["kind"] as? String).flatMap(CloudSessionKind.init(wireKind:)) else { return .gone }
        if openHere(kind, machine, id) { return .reveal(kind: kind, machine: machine, session: id) }
        return .attach(kind: kind, team: team, machine: machine, session: id)
    }
}
