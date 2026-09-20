import Foundation

extension CMUXCLI {
    /// Implements `cmux auth team` through the same authenticated socket
    /// actions used by the sidebar picker.
    func runAuthTeamCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        let subcommand = commandArgs.first?.lowercased() ?? "list"
        switch subcommand {
        case "list":
            let response = try client.sendV2(method: "auth.team.list")
            if jsonOutput {
                print(jsonString(response))
            } else {
                let teams = response["teams"] as? [[String: Any]] ?? []
                let selected = response["selected_team_id"] as? String
                for team in teams {
                    guard let id = team["id"] as? String else { continue }
                    let name = team["display_name"] as? String ?? id
                    print("\(id == selected ? "*" : " ") \(name) (\(id))")
                }
            }
        case "use":
            guard commandArgs.count == 2, !commandArgs[1].isEmpty else {
                throw CLIError(message: String(
                    localized: "cli.auth.team.useUsage",
                    defaultValue: "Usage: cmux auth team use <team-id>"
                ))
            }
            let response = try client.sendV2(
                method: "auth.team.use",
                params: ["team_id": commandArgs[1]]
            )
            if jsonOutput {
                print(jsonString(response))
            } else {
                let selected = response["selected_team_id"] as? String ?? commandArgs[1]
                print(String(format: String(
                    localized: "cli.auth.team.selected",
                    defaultValue: "Selected team: %@"
                ), selected))
            }
        case "create":
            let displayName = commandArgs.dropFirst().joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !displayName.isEmpty else {
                throw CLIError(message: String(
                    localized: "cli.auth.team.createUsage",
                    defaultValue: "Usage: cmux auth team create <name>"
                ))
            }
            let response = try client.sendV2(
                method: "auth.team.create",
                params: ["display_name": displayName]
            )
            if jsonOutput {
                print(jsonString(response))
            } else {
                let selected = response["selected_team_id"] as? String ?? displayName
                print(String(format: String(
                    localized: "cli.auth.team.created",
                    defaultValue: "Created and selected team: %@"
                ), selected))
            }
        default:
            throw CLIError(message: String(
                localized: "cli.auth.team.usage",
                defaultValue: "Usage: cmux auth team <list|use <team-id>|create <name>>"
            ))
        }
    }
}
