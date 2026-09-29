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
        case "members":
            var params: [String: Any] = [:]
            if let teamID = Self.authTeamOption(commandArgs, "--team") { params["team_id"] = teamID }
            let response = try client.sendV2(method: "auth.team.members", params: params, responseTimeout: 60)
            if jsonOutput {
                print(jsonString(response))
            } else {
                Self.printTeamRoster(response)
            }
        case "invite":
            var params: [String: Any] = [:]
            if let teamID = Self.authTeamOption(commandArgs, "--team") { params["team_id"] = teamID }
            params["role"] = Self.authTeamOption(commandArgs, "--role") ?? "member"
            let emails = Self.authTeamPositionals(commandArgs.dropFirst())
            guard !emails.isEmpty else {
                throw CLIError(message: String(
                    localized: "cli.auth.team.inviteUsage",
                    defaultValue: "Usage: cmux auth team invite <email>... [--role admin|member] [--team <team-id>]"
                ))
            }
            params["emails"] = emails
            let response = try client.sendV2(method: "auth.team.invite", params: params, responseTimeout: 60)
            if jsonOutput {
                print(jsonString(response))
            } else {
                let sent = response["sent"] as? [[String: Any]] ?? []
                let failed = response["failed"] as? [[String: Any]] ?? []
                for invitation in sent {
                    print(String(format: String(
                        localized: "cli.auth.team.invited",
                        defaultValue: "Invited %@"
                    ), invitation["email"] as? String ?? "?"))
                }
                for failure in failed {
                    print(String(format: String(
                        localized: "cli.auth.team.inviteFailed",
                        defaultValue: "Could not invite %1$@: %2$@"
                    ), failure["email"] as? String ?? "?", failure["code"] as? String ?? "?"))
                }
            }
        case "link":
            var params: [String: Any] = [:]
            if let teamID = Self.authTeamOption(commandArgs, "--team") { params["team_id"] = teamID }
            if let days = Self.authTeamOption(commandArgs, "--expires-days").flatMap(Int.init) {
                params["expires_in_days"] = days
            }
            if let uses = Self.authTeamOption(commandArgs, "--max-uses").flatMap(Int.init) {
                params["max_uses"] = uses
            }
            let response = try client.sendV2(method: "auth.team.invite_link", params: params, responseTimeout: 60)
            if jsonOutput {
                print(jsonString(response))
            } else if let link = response["invite_link"] as? [String: Any], let url = link["url"] as? String {
                print(url)
            }
        case "revoke-invite":
            guard commandArgs.count >= 2, !commandArgs[1].isEmpty else {
                throw CLIError(message: String(
                    localized: "cli.auth.team.revokeUsage",
                    defaultValue: "Usage: cmux auth team revoke-invite <invitation-id|link-id> [--team <team-id>]"
                ))
            }
            var params: [String: Any] = [:]
            if let teamID = Self.authTeamOption(commandArgs, "--team") { params["team_id"] = teamID }
            if Self.authTeamOption(commandArgs, "--link") != nil || commandArgs.contains("--link") {
                params["link_id"] = commandArgs[1]
            } else {
                params["invitation_id"] = commandArgs[1]
            }
            let response = try client.sendV2(method: "auth.team.revoke_invite", params: params, responseTimeout: 60)
            if jsonOutput {
                print(jsonString(response))
            } else {
                print(String(localized: "cli.auth.team.revoked", defaultValue: "Revoked."))
            }
        case "remove":
            guard commandArgs.count >= 2, !commandArgs[1].isEmpty else {
                throw CLIError(message: String(
                    localized: "cli.auth.team.removeUsage",
                    defaultValue: "Usage: cmux auth team remove <user-id> [--team <team-id>]"
                ))
            }
            var params: [String: Any] = ["user_id": commandArgs[1]]
            if let teamID = Self.authTeamOption(commandArgs, "--team") { params["team_id"] = teamID }
            let response = try client.sendV2(method: "auth.team.remove_member", params: params, responseTimeout: 60)
            if jsonOutput {
                print(jsonString(response))
            } else {
                print(String(localized: "cli.auth.team.removed", defaultValue: "Removed."))
            }
        default:
            throw CLIError(message: String(
                localized: "cli.auth.team.usage",
                defaultValue: "Usage: cmux auth team <list|use <team-id>|create <name>|members|invite <email>...|link|revoke-invite <id>|remove <user-id>>"
            ))
        }
    }

    /// `--flag value` or `--flag=value` anywhere after the subcommand.
    private static func authTeamOption(_ args: [String], _ flag: String) -> String? {
        var iterator = args.dropFirst().makeIterator()
        while let arg = iterator.next() {
            if arg == flag { return iterator.next() }
            if arg.hasPrefix(flag + "=") { return String(arg.dropFirst(flag.count + 1)) }
        }
        return nil
    }

    /// Positional arguments after the subcommand, skipping every `--flag value`.
    private static func authTeamPositionals(_ args: ArraySlice<String>) -> [String] {
        var result: [String] = []
        var skipNext = false
        for arg in args {
            if skipNext { skipNext = false; continue }
            if arg.hasPrefix("--") {
                skipNext = !arg.contains("=")
                continue
            }
            result.append(arg)
        }
        return result
    }

    private static func printTeamRoster(_ response: [String: Any]) {
        let team = response["team"] as? [String: Any] ?? [:]
        print("\(team["display_name"] as? String ?? "?") (\(team["id"] as? String ?? "?"))")
        if let billing = response["billing"] as? [String: Any], let limit = billing["member_limit"] as? Int {
            let members = response["members"] as? [[String: Any]] ?? []
            let pending = response["invitations"] as? [[String: Any]] ?? []
            print(String(format: String(
                localized: "teamMembers.seatSummary",
                defaultValue: "%1$d of %2$d seats used"
            ), members.count + pending.count, limit))
        }
        for member in response["members"] as? [[String: Any]] ?? [] {
            let name = member["display_name"] as? String ?? member["email"] as? String ?? member["user_id"] as? String ?? "?"
            let role = member["role"] as? String ?? "member"
            let viewer = (member["is_viewer"] as? Bool ?? false) ? "*" : " "
            print("\(viewer) \(name)  \(role)  \(member["user_id"] as? String ?? "")")
        }
        for invitation in response["invitations"] as? [[String: Any]] ?? [] {
            print(String(format: String(
                localized: "cli.auth.team.pendingInvitation",
                defaultValue: "  pending  %1$@  %2$@  %3$@"
            ), invitation["email"] as? String ?? "?", invitation["role"] as? String ?? "member", invitation["id"] as? String ?? ""))
        }
    }
}
