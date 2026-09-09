import Foundation

/// The CLI target does not compile `Sources/Cloud/VMClient.swift`, so it keeps
/// its own copy of the access modes; the app validates the wire value against
/// `VMPublicationAccessMode` when it handles `vm.publication_*`.
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
              cmux cloud domains zones
              cmux cloud domains verify <domain>
              cmux cloud domains publish <vm> <port> [--domain <hostname>] [--access personal|team|public] [--team <id>] [--org-slug <slug>] [--yes]
              cmux cloud domains access <hostname> <personal|team|public> [--team <id>] [--yes]
              cmux cloud domains grant <hostname> <email> [--expires <ISO-date>]
              cmux cloud domains ungrant <hostname> <email>
              cmux cloud domains grants <hostname>
              cmux cloud domains rm <hostname>

            Verify a domain you own first: `verify` prints the DNS records to add, then run it
            again to complete. `publish --domain` then accepts that domain or any one-label child.
            Generated names use <vm>--<organization>--<port>.cmux.sh and need no verification.
            Access defaults to the owning team or personal owner. Email grants apply to one port only.
            Public access requires confirmation; --yes confirms it for scripts. Add --json for JSON output.
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

        case "zones", "custom":
            guard arguments.isEmpty else { throw CLIError(message: Self.cloudDomainsUsage) }
            let response = try client.sendV2(method: "vm.domain_list", responseTimeout: 60)
            let domains = (response["domains"] as? [[String: Any]]) ?? []
            if jsonOutput {
                print(jsonString(["domains": domains]))
                return
            }
            guard !domains.isEmpty else {
                print(String(
                    localized: "cli.cloud.domains.custom.empty",
                    defaultValue: "No custom Cloud VM domains. Start one with `cmux cloud domains verify <domain>`."
                ))
                return
            }
            for (index, domain) in domains.enumerated() {
                if index > 0 { print("") }
                Self.printPublicationDomain(domain)
            }

        case "publish":
            let confirmed = arguments.contains("--yes")
            let (orgSlug, restAfterOrg) = parseOption(arguments.filter { $0 != "--yes" }, name: "--org-slug")
            let (domain, restAfterDomain) = parseOption(restAfterOrg, name: "--domain")
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
            ]
            if accessRaw != nil && access.mode != .public { params["accessMode"] = access.mode.rawValue }
            if let orgSlug { params["organizationSlug"] = orgSlug }
            if let domain = Self.nonempty(domain) { params["hostname"] = domain }
            if let teamID = access.teamID { params["teamId"] = teamID }
            var response = try client.sendV2(
                method: "vm.publication_create",
                params: params,
                responseTimeout: 120
            )
            if access.mode == .public {
                guard let publication = response["publication"] as? [String: Any],
                      let publicationID = Self.nonempty(publication["id"] as? String) else {
                    throw CLIError(message: String(
                        localized: "cli.cloud.domains.malformedResponse",
                        defaultValue: "The cmux app returned a publication response this CLI could not read."
                    ))
                }
                try Self.confirmPublicPublication(publication, confirmed: confirmed)
                response = try client.sendV2(method: "vm.publication_update", params: ["id": publicationID, "accessMode": "public", "confirmPublic": true], responseTimeout: 120)
            }
            try printPublicationMutation(response, jsonOutput: jsonOutput)

        case "verify":
            guard arguments.count == 1, let name = Self.nonempty(arguments[0]) else {
                throw CLIError(message: Self.cloudDomainsUsage)
            }
            // Verification is always about a zone; a publication hostname
            // resolves to the zone it belongs to on the app side.
            let response = try client.sendV2(
                method: "vm.domain_verify",
                params: ["name": name],
                responseTimeout: 120
            )
            guard let domain = response["domain"] as? [String: Any] else {
                throw CLIError(message: String(
                    localized: "cli.cloud.domains.malformedDomainResponse",
                    defaultValue: "The cmux app returned a domain response this CLI could not read."
                ))
            }
            if jsonOutput {
                print(jsonString(["domain": domain]))
            } else {
                Self.printPublicationDomain(domain)
            }

        case "access":
            let confirmed = arguments.contains("--yes")
            let (teamID, remaining) = parseOption(arguments.filter { $0 != "--yes" }, name: "--team")
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
            if access.mode == .public {
                let listed = try client.sendV2(method: "vm.publication_list", responseTimeout: 60)
                guard let publication = Self.publicationObjects(listed).first(where: {
                    ($0["id"] as? String) == publicationID || ($0["hostname"] as? String) == publicationID
                }) else { throw CLIError(message: Self.cloudDomainsUsage) }
                try Self.confirmPublicPublication(publication, confirmed: confirmed)
                params["id"] = publication["id"]
                params["confirmPublic"] = true
            }
            let response = try client.sendV2(
                method: "vm.publication_update",
                params: params,
                responseTimeout: 120
            )
            try printPublicationMutation(response, jsonOutput: jsonOutput)

        case "grant", "ungrant", "grants":
            let (expiresAt, remaining) = parseOption(arguments, name: "--expires")
            let expectedCount = subcommand == "grants" ? 1 : 2
            guard remaining.count == expectedCount,
                  !remaining.contains(where: { $0.hasPrefix("-") }),
                  expiresAt == nil || subcommand == "grant" else { throw CLIError(message: Self.cloudDomainsUsage) }
            var params: [String: Any] = ["id": remaining[0]]
            if expectedCount == 2 { params["email"] = remaining[1] }
            if let expiresAt { params["expiresAt"] = expiresAt }
            let response = try client.sendV2(method: "vm.publication_\(subcommand)", params: params, responseTimeout: 60)
            print(jsonString(response))

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

    private static func confirmPublicPublication(_ publication: [String: Any], confirmed: Bool) throws {
        let format = String(localized: "cli.cloud.domains.confirmPublic", defaultValue: "Public access lets anyone open %@ (VM %@, port %@). Continue? [y/N]")
        let warning = String(format: format, publication["hostname"] as? String ?? "?", publication["vmId"] as? String ?? "?", String(Self.intValue(publication["port"]) ?? 0))
        FileHandle.standardError.write(Data((warning + "\n").utf8))
        if !confirmed && readLine()?.lowercased() != "y" {
            throw CLIError(message: String(localized: "cli.cloud.domains.publicCancelled", defaultValue: "Public access was not enabled."))
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
                printPublicationVerifyHint(name: hostname)
            }
            return
        }
        let verificationState = (verification["state"] as? String) ?? unknown
        let verificationFormat = String(
            localized: "cli.cloud.domains.verificationState",
            defaultValue: "verification: %@"
        )
        print(String(format: verificationFormat, verificationState))
        // The app always emits all three instructions (`VMPublication.foundationObject`).
        if let instructions = verification["dnsInstructions"] as? [String: Any] {
            let ordered = ["verification", "routing", "certificate"]
                .compactMap { instructions[$0] as? [String: Any] }
            Self.printDNSInstructions(ordered, target: hostname)
        }
        // Verification is a zone-level step: re-running it also re-checks the
        // zone's certificate and finishes provisioning publications on it.
        if verificationState != "verified" || state != "active" {
            printPublicationVerifyHint(name: (verification["domain"] as? String) ?? hostname)
        }
    }

    /// A custom zone: its proof and certificate delegation, plus the publications
    /// that depend on it. Routing records for each hostname print with `list`.
    private static func printPublicationDomain(_ domain: [String: Any]) {
        let unknown = String(
            localized: "cli.cloud.domains.unknown",
            defaultValue: "unknown"
        )
        let hostname = (domain["hostname"] as? String) ?? "?"
        let id = (domain["id"] as? String) ?? "?"
        let verificationState = (domain["verificationState"] as? String) ?? unknown
        let certificateState = (domain["certificateState"] as? String) ?? unknown

        print(hostname)
        let detailsFormat = String(
            localized: "cli.cloud.domains.custom.details",
            defaultValue: "id: %1$@\nverification: %2$@\ncertificate: %3$@"
        )
        print(String(format: detailsFormat, id, verificationState, certificateState))

        let publications = (domain["publications"] as? [[String: Any]]) ?? []
        if publications.isEmpty {
            print(String(
                localized: "cli.cloud.domains.custom.noPublications",
                defaultValue: "publications: none"
            ))
        } else {
            let summary = publications.map { publication -> String in
                let publicationHostname = (publication["hostname"] as? String) ?? "?"
                let state = (publication["state"] as? String) ?? unknown
                return "\(publicationHostname) (\(state))"
            }.joined(separator: ", ")
            let publicationsFormat = String(
                localized: "cli.cloud.domains.custom.publications",
                defaultValue: "publications: %@"
            )
            print(String(format: publicationsFormat, summary))
        }

        // Ownership can be proven while the certificate delegation is still
        // missing, so the checklist stays visible until the certificate is live.
        guard verificationState != "verified" || certificateState != "active",
              let instructions = domain["dnsInstructions"] as? [[String: Any]] else {
            return
        }
        Self.printDNSInstructions(instructions, target: hostname)
        if instructions.contains(where: { ($0["purpose"] as? String) == "routing" }) {
            let noteFormat = String(
                localized: "cli.cloud.domains.dns.routingNote",
                defaultValue: "Routing: the apex record serves %@ itself; the * record serves every subdomain."
            )
            print(String(format: noteFormat, hostname))
            // Freestyle documents no stable edge IPs, so an A record is never offered.
            let fallbackFormat = String(
                localized: "cli.cloud.domains.dns.apexFallback",
                defaultValue: "No ALIAS/ANAME/flattening record at your DNS provider? Publish www.%@ and redirect the apex to it."
            )
            print(String(format: fallbackFormat, hostname))
        }
        printPublicationVerifyHint(name: hostname)
    }

    private static func printPublicationVerifyHint(name: String) {
        let verifyFormat = String(
            localized: "cli.cloud.domains.verifyHint",
            defaultValue: "After updating DNS: cmux cloud domains verify %@"
        )
        print(String(format: verifyFormat, name))
    }

    /// One aligned table per record set, each row labelled by what the record
    /// is for, so the reader never has to guess why an NS record is needed.
    private static func printDNSInstructions(_ records: [[String: Any]], target: String) {
        guard !records.isEmpty else { return }
        let headerFormat = String(
            localized: "cli.cloud.domains.dns.header",
            defaultValue: "Add these DNS records for %@:"
        )
        print(String(format: headerFormat, target))
        let rows: [[String]] = records.map { record in
            let recordTypes = (record["recordTypes"] as? [String]) ?? ["?"]
            return [
                Self.dnsPurposeLabel((record["purpose"] as? String) ?? ""),
                recordTypes.joined(separator: "/"),
                (record["name"] as? String) ?? "?",
                (record["value"] as? String) ?? "?",
            ]
        }
        let widths = (0..<3).map { column in rows.map { $0[column].count }.max() ?? 0 }
        for row in rows {
            let padded = (0..<3).map {
                row[$0].padding(toLength: widths[$0], withPad: " ", startingAt: 0)
            }
            print("  " + (padded + [row[3]]).joined(separator: "  "))
        }
    }

    private static func dnsPurposeLabel(_ purpose: String) -> String {
        switch purpose {
        case "verification":
            return String(localized: "cli.cloud.domains.dns.ownership", defaultValue: "ownership")
        case "routing":
            return String(localized: "cli.cloud.domains.dns.routing", defaultValue: "routing")
        case "certificate":
            return String(localized: "cli.cloud.domains.dns.certificate", defaultValue: "certificate")
        default:
            return purpose
        }
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? NSNumber { return value.intValue }
        if let value = raw as? String { return Int(value) }
        return nil
    }
}
