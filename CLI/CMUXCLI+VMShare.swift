import CmuxSurfaceCatalogModel
import Foundation

// MARK: - cmux vm share

extension CMUXCLI {
    static var vmShareUsage: String {
        String(localized: "cli.vm.share.usage", defaultValue: """
        Usage:
          cmux vm share <machine> <port>                      Who can open the port now.
          cmux vm share <machine> <port> --team [--team-id <id>]
          cmux vm share <machine> <port> --public [--yes]
          cmux vm share <machine> <port> --personal            A link only you can open.
          cmux vm share <machine> <port> --private             Stop sharing.

        A port is private by default: only you can open it, through your cmux VPN.
        Sharing gives it an HTTPS link (--personal and --team need a sign-in);
        every link of the port gets the chosen audience. --public lets anyone with
        the link open it without signing in and asks first; --yes confirms for
        scripts. --private removes generated links and keeps a custom domain for
        you only. Same as `cmux cloud domains publish|access|rm`; the Ports tab and
        the preview tab's share control show the result. Add --json for JSON.
        """)
    }

    /// `cmux vm share <machine> <port> [--team|--public|--personal|--private]`: the CLI
    /// face of the app's share control. Both execute `CloudPortSharePlan`, so a port's
    /// several links always end at one audience, and both write through the same
    /// `vm.publication_*` methods as `cmux cloud domains`.
    func runVMShareCommand(rest: [String], client: SocketClient, jsonOutput: Bool) throws {
        if rest.contains("--help") || rest.contains("-h") {
            print(Self.vmShareUsage)
            return
        }
        let confirmed = rest.contains("--yes") || rest.contains("-y")
        let (teamIDOption, afterTeamID) = parseOption(rest, name: "--team-id")
        let flags: [String: CloudPortShareTarget] = [
            "--team": .audience(.team),
            "--public": .audience(.public),
            "--personal": .audience(.personal),
            "--private": .stopSharing,
        ]
        let chosen = afterTeamID.compactMap { flags[$0] }
        let positional = afterTeamID.filter { flags[$0] == nil && !["--yes", "-y", "--json"].contains($0) }
        guard chosen.count <= 1,
              positional.count == 2,
              !positional.contains(where: { $0.hasPrefix("-") }),
              let port = Int(positional[1]), (1...65_535).contains(port) else {
            throw CLIError(message: Self.vmShareUsage)
        }
        if teamIDOption != nil, chosen.first != .audience(.team) {
            throw CLIError(message: String(
                localized: "cli.vm.share.teamIDOnly",
                defaultValue: "vm share: --team-id goes with --team."
            ))
        }
        let machine = try resolveVMShareMachine(positional[0], client: client)
        Self.rememberVMMachineLabel(positional[0], for: machine)
        let name = Self.vmMachineDisplayName(machine)
        let before = try vmSharePlan(machine: machine, port: port, client: client)

        guard let target = chosen.first else {
            if jsonOutput {
                print(jsonString(Self.vmShareJSON(machine: machine, port: port, plan: before, changed: false)))
            } else {
                Self.vmShareStatusLines(name: name, port: port, plan: before).forEach { print($0) }
                print(String(
                    format: String(
                        localized: "cli.vm.share.changeHint",
                        defaultValue: "Change it: cmux vm share %1$@ %2$@ --team | --public | --personal | --private"
                    ),
                    name,
                    String(port)
                ))
            }
            return
        }

        if before.requiresPublicConfirmation(target) {
            try Self.confirmVMSharePublic(name: name, port: port, confirmed: confirmed)
        }
        var current = before
        var after = before
        var changed = false
        var lastError: Error?
        // A publication mutation can time out after the server committed it.
        // Reconcile before retrying so a 503 cannot leave the CLI claiming a
        // private port while a wider publication is still live. Recompute the
        // plan after every attempt because one request may have partially run.
        for attempt in 0..<3 {
            let steps = current.steps(to: target)
            if steps.isEmpty {
                after = current
                break
            }
            do {
                var teamID: String?
                if target == .audience(.team) {
                    // The same team resolution as `cloud domains publish --access team`.
                    teamID = try validatedPublicationAccess("team", teamID: teamIDOption, client: client).teamID
                }
                for step in steps {
                    try runVMShareStep(step, machine: machine, port: port, teamID: teamID, client: client)
                }
                let refreshed = try vmSharePlan(machine: machine, port: port, client: client)
                if refreshed.steps(to: target).isEmpty {
                    after = refreshed
                    changed = true
                    break
                }
                current = refreshed
                if attempt == 2 {
                    throw lastError ?? CLIError(message: String(
                        localized: "cli.vm.share.changeFailed",
                        defaultValue: "Could not change who can open the port; the authoritative publication list did not settle."
                    ))
                }
            } catch {
                lastError = error
                guard let refreshed = try? vmSharePlan(machine: machine, port: port, client: client) else {
                    // The authoritative list is unavailable, so do not repeat
                    // a create/delete whose commit status is unknown.
                    throw error
                }
                if refreshed.steps(to: target).isEmpty {
                    after = refreshed
                    changed = true
                    break
                }
                current = refreshed
                if attempt == 2 { throw error }
            }
        }
        if jsonOutput {
            print(jsonString(Self.vmShareJSON(machine: machine, port: port, plan: after, changed: changed)))
            return
        }
        var lines = Self.vmShareStatusLines(name: name, port: port, plan: after)
        if !changed {
            lines[0] = String(
                format: String(localized: "cli.vm.share.unchanged", defaultValue: "Nothing to change: port %1$@ on %2$@ is already %3$@."),
                String(port),
                name,
                Self.vmShareAudienceSentence(after.current)
            )
        }
        lines.forEach { print($0) }
        if target == .stopSharing {
            for kept in after.customDomainsKeptByStopSharing {
                print(String(
                    format: String(
                        localized: "cli.vm.share.keptCustomDomain",
                        defaultValue: "Kept %1$@ for you only (sign-in required). Remove it: cmux cloud domains rm %1$@"
                    ),
                    kept.hostname
                ))
            }
        }
    }

    /// The port's publications, read fresh before every decision.
    func vmSharePlan(machine: String, port: Int, client: SocketClient) throws -> CloudPortSharePlan {
        let response = try client.sendV2(method: "vm.publication_list", responseTimeout: 60)
        let refs = ((response["publications"] as? [[String: Any]]) ?? []).compactMap(CloudPortPublicationRef.init(foundationObject:))
        return CloudPortSharePlan(publications: refs, machineID: machine, port: port)
    }

    /// One plan step over the socket. A new public link is created privately and
    /// then opened, like `cloud domains publish --access public`, so a failure in
    /// between never leaves it public.
    func runVMShareStep(_ step: CloudPortShareStep, machine: String, port: Int, teamID: String?, client: SocketClient) throws {
        switch step {
        case .create(let audience):
            var params: [String: Any] = [
                "vmId": machine,
                "port": port,
                "accessMode": audience == .public ? CloudPortShareAudience.personal.rawValue : audience.rawValue,
            ]
            if audience == .team, let teamID { params["teamId"] = teamID }
            let response = try client.sendV2(method: "vm.publication_create", params: params, responseTimeout: 120)
            guard audience == .public else { return }
            guard let id = (response["publication"] as? [String: Any])?["id"] as? String, !id.isEmpty else {
                throw CLIError(message: String(
                    localized: "cli.cloud.domains.malformedResponse",
                    defaultValue: "The cmux app returned a publication response this CLI could not read."
                ))
            }
            _ = try client.sendV2(
                method: "vm.publication_update",
                params: ["id": id, "accessMode": "public", "confirmPublic": true],
                responseTimeout: 120
            )
        case .update(let id, let audience):
            var params: [String: Any] = ["id": id, "accessMode": audience.rawValue]
            if audience == .team, let teamID { params["teamId"] = teamID }
            if audience == .public { params["confirmPublic"] = true }
            _ = try client.sendV2(method: "vm.publication_update", params: params, responseTimeout: 120)
        case .delete(let id):
            _ = try client.sendV2(method: "vm.publication_delete", params: ["id": id], responseTimeout: 120)
        }
    }

    /// An id or a label, through the resolver every `cmux vm` verb uses. An app that
    /// cannot list machines gets the argument as typed.
    func resolveVMShareMachine(_ selector: String, client: SocketClient) throws -> String {
        guard let listed = try? client.sendV2(method: "vm.list", responseTimeout: 60),
              let vms = listed["vms"] as? [[String: Any]] else { return selector }
        switch VMMachineSelectorResolver().resolve(selector, vms: vms) {
        case .id(let id), .label(id: let id):
            return id
        case .ambiguous(let matches):
            let list = matches.map { "  \($0.id)  \($0.label)" }.joined(separator: "\n")
            throw CLIError(message: String(
                format: String(localized: "cli.vm.machineLabel.ambiguous", defaultValue: "%1$@ is the label of more than one machine; use an id:\n%2$@"),
                selector, list
            ))
        case .unknown:
            throw CLIError(message: String(
                format: String(localized: "cli.vm.share.unknownMachine", defaultValue: "vm share: no machine named %@. Run `cmux vm ls` to see your machines."),
                selector
            ))
        }
    }

    /// The question before anything becomes public. It names the audience, and only
    /// "y" (or `--yes`) continues; a script without a terminal is refused.
    static func confirmVMSharePublic(name: String, port: Int, confirmed: Bool) throws {
        if confirmed { return }
        let warning = String(
            format: String(
                localized: "cli.vm.share.confirmPublic",
                defaultValue: "Public lets anyone on the internet who has the link open port %1$@ on %2$@ without signing in. Continue? [y/N]"
            ),
            String(port),
            name
        )
        cliWriteStderr(warning + "\n")
        guard readLine()?.trimmingCharacters(in: .whitespaces).lowercased() == "y" else {
            throw CLIError(message: String(
                localized: "cli.vm.share.publicCancelled",
                defaultValue: "Not made public. Pass --yes to confirm from a script."
            ))
        }
    }

    /// "Port 3000 on brave-otter: shared with your team (sign-in required)." plus one line per link.
    static func vmShareStatusLines(name: String, port: Int, plan: CloudPortSharePlan) -> [String] {
        var lines = [String(
            format: String(localized: "cli.vm.share.status", defaultValue: "Port %1$@ on %2$@: %3$@."),
            String(port),
            name,
            vmShareAudienceSentence(plan.current)
        )]
        for publication in plan.publications {
            lines.append("  \(publication.url)  \(vmPortSharingLabel(publication.sharing))")
        }
        return lines
    }

    static func vmShareAudienceSentence(_ sharing: CloudPortSharing) -> String {
        switch sharing {
        case .unshared:
            return String(localized: "cli.vm.share.audience.private", defaultValue: "private (only you, through your cmux VPN)")
        case .personal:
            return String(localized: "cli.vm.share.audience.personal", defaultValue: "a link only you can open (sign-in required)")
        case .team:
            return String(localized: "cli.vm.share.audience.team", defaultValue: "shared with your team (sign-in required)")
        case .public:
            return String(localized: "cli.vm.share.audience.public", defaultValue: "PUBLIC (anyone with the link)")
        }
    }

    static func vmShareJSON(machine: String, port: Int, plan: CloudPortSharePlan, changed: Bool) -> [String: Any] {
        [
            "machine": machine,
            "port": port,
            "shared": plan.current.rawValue,
            "changed": changed,
            "links": plan.publications.map { publication -> [String: Any] in
                [
                    "id": publication.id,
                    "hostname": publication.hostname,
                    "url": publication.url,
                    "shared": publication.sharing.rawValue,
                    "generated": publication.isGeneratedDomain,
                ]
            },
        ]
    }
}
