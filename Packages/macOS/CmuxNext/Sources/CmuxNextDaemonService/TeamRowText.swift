public import CmuxNextActions
public import CmuxNextAgentPane
public import CmuxNextCloud
import CmuxNextCompat

/// How a team row reads on every team list (the account menu, Switch Active Team, the menu bar):
/// a person icon for the person's own team and a people icon for a shared one, and a second line
/// that says whose it is and its plan when the team has one. Leo, 2026-11-09, of the team row:
/// "i guess is team? it's kinda hard to realize tho"; of Switch Active Team: "what is this?"
@MainActor public struct TeamRowText: Equatable, Sendable {
    public var symbol: String
    public var subtitle: String

    /// `email` is the signed-in account's, shown under the person's own team.
    public init(_ row: ActiveTeam.Row, email: String?) {
        symbol = row.kind == .personal ? "person" : "person.2"
        let who = row.kind == .personal ? (email.flatMap { $0.isEmpty ? nil : $0 } ?? CloudStrings.teamKindPersonal) : CloudStrings.teamKindTeam
        subtitle = row.plan.map { "\(who) · \(CloudStrings.teamPlan(Self.planName($0)))" } ?? who
    }

    /// A plan id as its product name ("pro" is "Pro"): the id the server wrote, capitalized.
    static func planName(_ id: String) -> String {
        id.prefix(1).uppercased() + id.dropFirst()
    }

    /// The account's teams as the values of Switch Active Team's `team` argument.
    public static func suggestions(_ auth: CloudAuth) -> [ActionEnumCase] {
        auth.activeTeam.rows.map { row in
            let text = TeamRowText(row, email: auth.user?.primaryEmail)
            return ActionEnumCase(value: row.id, title: row.title, subtitle: text.subtitle, symbol: text.symbol)
        }
    }

    /// The active team as the agent pane's `cloudMachine.list` reply names it; nil signed out or before membership loads.
    public static func paneTeam(_ auth: CloudAuth) -> AgentPaneCloudMachines.Team? {
        guard auth.isSignedIn, let row = auth.activeTeam.activeRow else { return nil }
        return AgentPaneCloudMachines.Team(id: row.id, name: row.title, personal: row.kind == .personal)
    }

    /// The account's teams as the agent pane's `cloudMachine.list` reply lists them; none signed out.
    public static func paneTeams(_ auth: CloudAuth) -> [AgentPaneCloudMachines.Team] {
        guard auth.isSignedIn else { return [] }
        return auth.activeTeam.rows.map { AgentPaneCloudMachines.Team(id: $0.id, name: $0.title, personal: $0.kind == .personal) }
    }

    /// The active team as the Machines section's Cloud header names it (`MachineSectionPageProvider` `cloudTeam`).
    public static func machinesTeam(_ auth: CloudAuth) -> (name: String, personal: Bool)? {
        paneTeam(auth).map { ($0.name, $0.personal) }
    }

    /// Follows the signed-in account's active team (who, which team, its name and kind): `changed`
    /// runs on each change after the first read, as long as the task lives.
    public static func follow(_ auth: CloudAuth, changed: @escaping @MainActor @Sendable () -> Void) -> Task<Void, Never> {
        let key: @MainActor @Sendable () -> String? = { [weak auth] in
            auth.map { "\($0.accountKey ?? "")|\(paneTeam($0).map { "\($0.personal)|\($0.name)" } ?? "")" }
        }
        // task-owner: the caller (AgentPaneCloudMachines.teamWatch); event-driven (Observation)
        return Task {
            var first = true
            for await _ in ObservationStream(key) {
                if first { first = false } else { changed() }
            }
        }
    }

    /// The active team's icon (the menu bar's team row); a shared team's before membership loads.
    public static func symbol(_ auth: CloudAuth) -> String {
        auth.activeTeam.activeRow.map { TeamRowText($0, email: nil).symbol } ?? "person.2"
    }
}
