import Foundation

/// The per-invocation CodeRouter team scope shared by the app and the CLI.
///
/// CodeRouter organization IDs are cmux (Stack) team IDs: the organization
/// catalog (`/api/coderouter/organizations`) lists each member team under its
/// Stack team ID. A CLI that reports the `team-override` capability reads
/// `CODEROUTER_TEAM_ID` and scopes that single invocation to the organization,
/// leaving the user's persisted active organization untouched. Older CLIs
/// ignore the variable, so setting it is always harmless.
enum CoderouterTeamEnvironment {
    /// The environment variable that scopes one CodeRouter invocation.
    static let variable = "CODEROUTER_TEAM_ID"
    /// The `capabilities --json` feature that says the variable is honored.
    static let teamOverrideFeature = "team-override"

    /// Whether the invocation already names its team, through the variable
    /// (present at all, even empty) or a `--team` option before a `--`
    /// terminator. cmux never overrides a team the user chose.
    static func hasExplicitTeam(arguments: [String], environment: [String: String]) -> Bool {
        if environment[variable] != nil { return true }
        for argument in arguments {
            if argument == "--" { return false }
            if argument == "--team" || argument.hasPrefix("--team=") { return true }
        }
        return false
    }

    /// The child environment for `cmux cr`: the selected cmux team is added
    /// only when the user did not name a team and the app reported one.
    static func environment(
        _ environment: [String: String],
        arguments: [String],
        appTeamID: String?
    ) -> [String: String] {
        guard let appTeamID = normalizedTeamID(appTeamID),
              !hasExplicitTeam(arguments: arguments, environment: environment) else {
            return environment
        }
        var scoped = environment
        scoped[variable] = appTeamID
        return scoped
    }

    /// The selected team from an `auth.status` socket result, or nil when the
    /// app is not signed in, has no team scope yet, or reports an ID that is
    /// not a Stack team UUID (and so cannot be a CodeRouter organization ID).
    static func selectedTeamID(fromAuthStatus status: [String: Any]) -> String? {
        guard status["signed_in"] as? Bool == true,
              let teamID = normalizedTeamID(status["selected_team_id"] as? String),
              UUID(uuidString: teamID) != nil else { return nil }
        return teamID
    }

    /// Whether a `capabilities --json` payload lists `team-override`. Anything
    /// unreadable is treated as an older CLI.
    static func supportsTeamOverride(capabilitiesJSON data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = object["features"] as? [String] else { return false }
        return features.contains(teamOverrideFeature)
    }

    /// A POSIX shell assignment prefix that scopes one command to a team.
    static func shellAssignment(teamID: String) -> String {
        "\(variable)='" + teamID.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func normalizedTeamID(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
