import Foundation

/// The account's teams as every team list shows them (the account menu, Switch Active Team, the
/// menu bar), from Rust's rule (cmux-cloud-config `auth::team_rows`): whose each team is, its plan,
/// and the one active row.
extension ActiveTeam {
    /// One team of a list.
    public nonisolated struct Row: Decodable, Equatable, Sendable {
        public enum Kind: String, Decodable, Sendable {
            /// The person's own team.
            case personal
            /// A team shared with other people.
            case team
        }

        public var id: String
        public var title: String
        public var kind: Kind
        /// The team cmux works in now: at most one row is.
        public var active: Bool
        /// The plan id, lowercased, when the team has one.
        public var plan: String?

        public init(id: String, title: String, kind: Kind, active: Bool, plan: String? = nil) {
            (self.id, self.title, self.kind, self.active, self.plan) = (id, title, kind, active, plan)
        }
    }

    /// The teams this device may use, in the account's order, the active one checked.
    public var rows: [Row] {
        Self.rows(teams.map { ($0.id, $0.displayName, $0.plan) }, active: id)
    }

    /// The active team's row, once membership has loaded.
    public var activeRow: Row? { rows.first(where: \.active) }

    nonisolated static func rows(_ teams: [(id: String, name: String, plan: String?)], active: String?) -> [Row] {
        struct Facts: Encodable { var id: String, name: String, plan: String? }
        struct Request: Encodable { var teams: [Facts], active: String? }
        struct Answer: Decodable { var rows: [Row] }
        let request = Request(teams: teams.map { Facts(id: $0.id, name: $0.name, plan: $0.plan) }, active: active)
        // An FFI that does not answer still lists every team, by name, with the active one checked.
        return CloudStartCore().call("cloud_auth_team_rows", request, as: Answer.self)?.rows
            ?? teams.map { Row(id: $0.id, title: $0.name, kind: .team, active: $0.id == active) }
    }
}
