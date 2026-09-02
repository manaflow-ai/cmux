import Foundation

private enum CloudDomainAccessMode: String {
    case personal
    case team
    case `public`
}

extension CMUXCLI {
    static let cloudDomainsUsage = String(
        localized: "cli.cloud.domains.usage",
        defaultValue: """
            Usage:
              cmux cloud domains [list]
              cmux cloud domains publish <vm> <port> [--domain <hostname>] [--access personal|team|public] [--team <id>]
              cmux cloud domains verify <publication-id>
              cmux cloud domains access <publication-id> <personal|team|public> [--team <id>]
              cmux cloud domains rm <publication-id>

            Add `--json` to any command for stable JSON output.
            """
    )

    func runCloudDomainsCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        let subcommand = commandArgs.first?.lowercased() ?? "list"
        let arguments = Array(commandArgs.dropFirst())

        switch subcommand {
        case "list", "ls":
            guard arguments.isEmpty else { throw CLIError(message: Self.cloudDomainsUsage) }
            let response = try client.sendV2(method: "vm.publication_list", responseTimeout: 60)
            if jsonOutput {
                print(jsonString(Self.normalizedPublicationListResponse(response)))
                return
            }
            let publications = Self.publicationObjects(response)
            guard !publications.isEmpty else {
                print(String(
                    localized: "cli.cloud.domains.empty",
                    defaultValue: "No published Cloud VM domains."
                ))
                return
            }
            for (index, publication) in publications.enumerated() {
                if index > 0 { print("") }
                Self.printPublication(publication)
            }

        case "publish":
            let (domain, restAfterDomain) = parseOption(arguments, name: "--domain")
            let (accessRaw, restAfterAccess) = parseOption(restAfterDomain, name: "--access")
            let (teamID, remaining) = parseOption(restAfterAccess, name: "--team")
            guard remaining.count == 2,
                  !remaining.contains(where: { $0.hasPrefix("-") }),
                  let port = Int(remaining[1]), (1...65_535).contains(port) else {
                throw CLIError(message: Self.cloudDomainsUsage)
            }
            let access = try Self.validatedPublicationAccess(
                accessRaw ?? CloudDomainAccessMode.personal.rawValue,
                teamID: teamID
            )
            var params: [String: Any] = [
                "vmId": remaining[0],
                "port": port,
                "accessMode": access.mode.rawValue,
            ]
            if let domain = Self.nonempty(domain) { params["hostname"] = domain }
            if let teamID = access.teamID { params["teamId"] = teamID }
            let response = try client.sendV2(
                method: "vm.publication_create",
                params: params,
                responseTimeout: 120
            )
            try printPublicationMutation(response, jsonOutput: jsonOutput)

        case "verify":
            guard arguments.count == 1, let publicationID = Self.nonempty(arguments[0]) else {
                throw CLIError(message: Self.cloudDomainsUsage)
            }
            let response = try client.sendV2(
                method: "vm.publication_verify",
                params: ["id": publicationID],
                responseTimeout: 120
            )
            try printPublicationMutation(response, jsonOutput: jsonOutput)

        case "access":
            let (teamID, remaining) = parseOption(arguments, name: "--team")
            guard remaining.count == 2,
                  !remaining.contains(where: { $0.hasPrefix("-") }),
                  let publicationID = Self.nonempty(remaining[0]) else {
                throw CLIError(message: Self.cloudDomainsUsage)
            }
            let access = try Self.validatedPublicationAccess(remaining[1], teamID: teamID)
            var params: [String: Any] = [
                "id": publicationID,
                "accessMode": access.mode.rawValue,
            ]
            if let teamID = access.teamID { params["teamId"] = teamID }
            let response = try client.sendV2(
                method: "vm.publication_update",
                params: params,
                responseTimeout: 120
            )
            try printPublicationMutation(response, jsonOutput: jsonOutput)

        case "rm", "remove", "delete":
            guard arguments.count == 1, let publicationID = Self.nonempty(arguments[0]) else {
                throw CLIError(message: Self.cloudDomainsUsage)
            }
            let response = try client.sendV2(
                method: "vm.publication_delete",
                params: ["id": publicationID],
                responseTimeout: 120
            )
            if jsonOutput {
                print(jsonString(response))
            } else {
                let format = String(
                    localized: "cli.cloud.domains.removed",
                    defaultValue: "Removed publication %@."
                )
                print(String(format: format, publicationID))
            }

        case "help", "--help", "-h":
            print(Self.cloudDomainsUsage)

        default:
            throw CLIError(message: Self.cloudDomainsUsage)
        }
    }

    private static func validatedPublicationAccess(
        _ rawValue: String,
        teamID: String?
    ) throws -> (mode: CloudDomainAccessMode, teamID: String?) {
        guard let mode = CloudDomainAccessMode(rawValue: rawValue.lowercased()) else {
            throw CLIError(message: String(
                localized: "cli.cloud.domains.invalidAccess",
                defaultValue: "Access must be personal, team, or public."
            ))
        }
        let normalizedTeamID = nonempty(teamID)
        if mode == .team, normalizedTeamID == nil {
            throw CLIError(message: String(
                localized: "cli.cloud.domains.teamRequired",
                defaultValue: "Team access requires `--team <id>`."
            ))
        }
        if mode != .team, normalizedTeamID != nil {
            throw CLIError(message: String(
                localized: "cli.cloud.domains.teamOnly",
                defaultValue: "`--team` can only be used with team access."
            ))
        }
        return (mode, normalizedTeamID)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func publicationObjects(_ response: [String: Any]) -> [[String: Any]] {
        (response["publications"] as? [[String: Any]]) ?? []
    }

    private static func normalizedPublicationListResponse(_ response: [String: Any]) -> [String: Any] {
        ["publications": publicationObjects(response)]
    }

    private func printPublicationMutation(
        _ response: [String: Any],
        jsonOutput: Bool
    ) throws {
        guard let publication = (response["publication"] as? [String: Any])
            ?? (response["id"] == nil ? nil : response) else {
            throw CLIError(message: String(
                localized: "cli.cloud.domains.malformedResponse",
                defaultValue: "The cmux app returned a publication response this CLI could not read."
            ))
        }
        let normalized: [String: Any] = ["publication": publication]
        if jsonOutput {
            print(jsonString(normalized))
        } else {
            Self.printPublication(publication)
        }
    }

    private static func printPublication(_ publication: [String: Any]) {
        let id = (publication["id"] as? String) ?? "?"
        let hostname = (publication["hostname"] as? String) ?? "?"
        let url = (publication["url"] as? String) ?? "https://\(hostname)"
        let domainKind = (publication["domainKind"] as? String) ?? "?"
        let vmID = (publication["vmId"] as? String) ?? "?"
        let port = Self.intValue(publication["port"]).map(String.init) ?? "?"
        let accessMode = (publication["accessMode"] as? String) ?? "?"
        let teamID = nonempty(publication["teamId"] as? String)
        let access: String
        if let teamID {
            let accessFormat = String(
                localized: "cli.cloud.domains.teamAccess",
                defaultValue: "%1$@ (team %2$@)"
            )
            access = String(format: accessFormat, accessMode, teamID)
        } else {
            access = accessMode
        }
        let unknown = String(
            localized: "cli.cloud.domains.unknown",
            defaultValue: "unknown"
        )
        let state = (publication["state"] as? String) ?? unknown
        let revision = Self.intValue(publication["routingRevision"]).map(String.init) ?? "0"

        print(url)
        let detailsFormat = String(
            localized: "cli.cloud.domains.details",
            defaultValue: "id: %1$@\nvm: %2$@:%3$@\naccess: %4$@\nstate: %5$@\nrouting revision: %6$@\ndomain: %7$@"
        )
        print(String(format: detailsFormat, id, vmID, port, access, state, revision, domainKind))

        guard let verification = publication["verification"] as? [String: Any] else {
            if domainKind == "generated" {
                print(String(
                    localized: "cli.cloud.domains.verification.generated",
                    defaultValue: "verification: not required (cmux domain)"
                ))
            } else {
                let verificationFormat = String(
                    localized: "cli.cloud.domains.verificationState",
                    defaultValue: "verification: %@"
                )
                print(String(format: verificationFormat, state))
                printPublicationVerifyHint(id: id)
            }
            return
        }
        let verificationState = (verification["state"] as? String) ?? unknown
        let verificationFormat = String(
            localized: "cli.cloud.domains.verificationState",
            defaultValue: "verification: %@"
        )
        print(String(format: verificationFormat, verificationState))
        if let instructions = verification["dnsInstructions"] as? [String: Any] {
            if let ownership = instructions["verification"] as? [String: Any] {
                Self.printDNSInstruction(ownership)
            } else if let legacyOwnership = verification["verificationRecord"] as? [String: Any] {
                Self.printDNSInstruction(legacyOwnership)
            }
            if let routing = instructions["routing"] as? [String: Any] {
                Self.printDNSInstruction(routing)
            }
            if let certificate = instructions["certificate"] as? [String: Any] {
                Self.printDNSInstruction(certificate)
            }
        }
        printPublicationVerifyHint(id: id)
    }

    private static func printPublicationVerifyHint(id: String) {
        let verifyFormat = String(
            localized: "cli.cloud.domains.verifyHint",
            defaultValue: "After updating DNS: cmux cloud domains verify %@"
        )
        print(String(format: verifyFormat, id))
    }

    private static func printDNSInstruction(_ instruction: [String: Any]) {
        let recordTypes = (instruction["recordTypes"] as? [String])
            ?? (instruction["record_types"] as? [String])
            ?? (instruction["type"] as? String).map { [$0] }
            ?? ["?"]
        let name = (instruction["name"] as? String) ?? "?"
        let value = (instruction["value"] as? String) ?? "?"
        print("\(recordTypes.joined(separator: "/")) \(name) \(value)")
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? NSNumber { return value.intValue }
        if let value = raw as? String { return Int(value) }
        return nil
    }
}
