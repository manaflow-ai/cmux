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

    /// Commands whose remaining arguments belong to another program, exactly
    /// as coderouter's `extract_team_flag` lists them. A `--team` after one
    /// of these is the child's argument, not coderouter's.
    static let passThroughCommands: Set<String> = ["codex", "opencode", "pi", "naked", "direct", "claude-david"]

    /// Commands that manage the saved default organization or the sign-in
    /// itself. Pinning them to the app's team would be wrong (`org switch`
    /// would not change what later commands use), so they run unpinned.
    static let persistedScopeCommands: Set<String> = [
        "org", "organization", "team", "login", "logout", "auth", "transfer",
    ]

    /// The coderouter command word and whether a coderouter `--team` option
    /// is present, parsed the way coderouter's `extract_team_flag` does: the
    /// option counts anywhere until the first word is a pass-through command,
    /// `--team` takes the next argument as its value, and `--` means nothing.
    static func parse(arguments: [String]) -> (command: String?, hasTeamOption: Bool) {
        var command: String?
        var hasTeamOption = false
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            if argument == "--team" {
                hasTeamOption = true
                index += 2
                continue
            }
            if argument.hasPrefix("--team=") {
                hasTeamOption = true
            } else if command == nil {
                command = argument
                if passThroughCommands.contains(argument) { break }
            }
            index += 1
        }
        return (command, hasTeamOption)
    }

    /// Whether the invocation already names its team, through the variable
    /// (present at all, even empty) or coderouter's own `--team` option.
    /// cmux never overrides a team the user chose.
    static func hasExplicitTeam(arguments: [String], environment: [String: String]) -> Bool {
        environment[variable] != nil || parse(arguments: arguments).hasTeamOption
    }

    /// Whether `cmux cr` should pin this invocation to the app's team: the
    /// user named none, and the command does not manage the saved default.
    static func wantsAppTeam(arguments: [String], environment: [String: String]) -> Bool {
        guard !hasExplicitTeam(arguments: arguments, environment: environment) else { return false }
        guard let command = parse(arguments: arguments).command else { return true }
        return !persistedScopeCommands.contains(command)
    }

    /// The child environment for `cmux cr`: the selected cmux team is added
    /// only when ``wantsAppTeam(arguments:environment:)`` and the app
    /// reported one.
    static func environment(
        _ environment: [String: String],
        arguments: [String],
        appTeamID: String?
    ) -> [String: String] {
        guard let appTeamID = normalizedTeamID(appTeamID),
              wantsAppTeam(arguments: arguments, environment: environment) else {
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
