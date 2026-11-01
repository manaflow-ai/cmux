public import CMUXAuthCore
import Foundation

/// The rows of a team Cloud machine's Share Machine… page: every teammate but the machine's
/// creator (who always starts chats there), each marked shared or not, shared ones first; a
/// grant whose teammate has left the team stays listed so it can still be taken back. The server
/// decides who may change shares (web/services/vms/chatGrants.ts share_chat); ``canShare`` only
/// words the page ahead of its answer.
public struct CloudMachineShareRoster: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public let userID: String
        public let name: String
        /// The teammate's email when it is not their name, else nil.
        public let email: String?
        public let shared: Bool
    }

    public let rows: [Row]
    /// The viewer is the machine's creator or a team admin.
    public let canShare: Bool

    /// - Parameters:
    ///   - members: The machine's team (``CMUXTeamDetail/members``).
    ///   - viewer: The signed-in person on that team.
    ///   - creator: The machine's creator (``CloudMachine/createdBy``), nil when unknown.
    ///   - grants: The machine's grants (``CloudAPIClient/chatGrants(_:)``).
    public init(members: [CMUXTeamDetail.Member], viewer: CMUXTeamDetail.Viewer, creator: String?, grants: [CloudChatGrant]) {
        let granted = Set(grants.map(\.userId))
        var rows = members.filter { $0.userId != creator }.map { member -> Row in
            let name = [member.displayName, member.email].lazy.compactMap { $0?.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty } ?? member.userId
            return Row(userID: member.userId, name: name, email: member.email == name ? nil : member.email,
                       shared: granted.contains(member.userId))
        }
        let listed = Set(rows.map(\.userID))
        rows += grants.filter { !listed.contains($0.userId) && $0.userId != creator }
            .map { Row(userID: $0.userId, name: $0.userId, email: nil, shared: true) }
        self.rows = rows.sorted { lhs, rhs in
            if lhs.shared != rhs.shared { return lhs.shared }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        canShare = viewer.userId == creator || viewer.role == .admin
    }
}

/// A refused share, keyed on the Cloud API's `error` code, never its words.
public enum CloudMachineShareRefusal: Equatable, Sendable {
    /// `vm_chat_share_forbidden`: only the creator or a team admin shares.
    case forbidden
    /// `vm_chat_grants_personal_machine`: a personal-account machine is its creator's alone.
    case personalMachine
    /// `vm_chat_grants_unavailable`: the server could not read the team; try again.
    case unavailable
    /// `vm_chat_grant_not_member`: the teammate is no longer on the machine's team.
    case notMember

    public init?(code: String?) {
        switch code {
        case "vm_chat_share_forbidden": self = .forbidden
        case "vm_chat_grants_personal_machine": self = .personalMachine
        case "vm_chat_grants_unavailable": self = .unavailable
        case "vm_chat_grant_not_member": self = .notMember
        default: return nil
        }
    }

    /// The code the agent pane keys its card on (webviews machineShare.ts).
    public var code: String {
        switch self {
        case .forbidden: "vm_chat_share_forbidden"
        case .personalMachine: "vm_chat_grants_personal_machine"
        case .unavailable: "vm_chat_grants_unavailable"
        case .notMember: "vm_chat_grant_not_member"
        }
    }
}
