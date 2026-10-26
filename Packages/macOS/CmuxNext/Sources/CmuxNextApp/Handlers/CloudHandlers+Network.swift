import AppKit
import CmuxNextActions
import CmuxNextCloud
import CmuxNextCompat
import CmuxNextRemote
import CmuxNextWakeups

extension CloudHandlers {
    static func bindNetworkActions(into registry: ActionRegistry, context: AppActionContext, reason: @escaping @MainActor () -> String?) {
        let cloud = context.services.cloud
        bind("cloudTunnelAttach", registry, reason: reason) { invocation in
            let networkID = try networkArgument(invocation)
            runTracked("attach Cloud tunnel network", context) { try await cloud.api.attachTunnelNetwork(deviceFingerprint: cloud.localDeviceID(), networkID: networkID) }
        }
        bind("cloudTunnelDetach", registry, reason: reason) { invocation in
            let networkID = try networkArgument(invocation)
            runTracked("detach Cloud tunnel network", context) { try await cloud.api.detachTunnelNetwork(deviceFingerprint: cloud.localDeviceID(), networkID: networkID) }
        }
        bind("cloudTunnelRotateKey", registry, reason: reason) { invocation in
            guard let key = invocation["publicKey"]?.stringValue else { throw ActionFailure(message: CloudStrings.publicKeyRequired) }
            runTracked("rotate Cloud tunnel key", context) { _ = try await cloud.api.rotateTunnelKey(deviceFingerprint: cloud.localDeviceID(), publicKey: key) }
        }
        bind("cloudNetworkList", registry, reason: reason) { invocation in
            answer("list Cloud networks", invocation, context) {
                let networks = try await cloud.api.listNetworks()
                let lines = networks.map { network in [network.id, "(\(network.scope))", network.cidr ?? ""].joined(separator: " ") }
                return CloudAnswer(title: CloudStrings.networkTitle, text: lines.joined(separator: "\n"), fields: ["count": .int(networks.count)])
            }
        }
        bind("cloudFirewallList", registry, reason: reason) { invocation in
            answer("list Cloud firewall rules", invocation, context) {
                let rules = try await cloud.api.listFirewallRules()
                return CloudAnswer(title: CloudStrings.firewallTitle, text: rules.map { "\($0.id): \($0.description ?? $0.action)" }.joined(separator: "\n"),
                                   fields: ["count": .int(rules.count)])
            }
        }
        bind("cloudFirewallGet", registry, reason: reason) { invocation in
            let ruleID = try networkArgument(invocation)
            answer("get Cloud firewall rule", invocation, context) {
                let rule = try await cloud.api.getFirewallRule(ruleID)
                return CloudAnswer(title: CloudStrings.firewallTitle, text: "\(rule.id): \(rule.description ?? rule.action)",
                                   fields: ["id": .string(rule.id), "action": .string(rule.action)])
            }
        }
        bind("cloudFirewallDelete", registry, reason: reason) { invocation in
            let ruleID = try networkArgument(invocation)
            runTracked("delete Cloud firewall rule", context) { try await cloud.api.deleteFirewallRule(ruleID) }
        }
        bind("cloudFirewallCreate", registry, reason: reason) { invocation in
            guard let json = invocation["path"]?.stringValue, let data = json.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sourceData = try? JSONSerialization.data(withJSONObject: value["source"] ?? [:]),
                  let destinationData = try? JSONSerialization.data(withJSONObject: value["destination"] ?? [:]),
                  let source = try? JSONDecoder().decode(CloudFirewallEndpoint.self, from: sourceData),
                  let destination = try? JSONDecoder().decode(CloudFirewallEndpoint.self, from: destinationData) else {
                throw ActionFailure(message: "Pass path as JSON with source and destination firewall endpoints.")
            }
            runTracked("create Cloud firewall rule", context) { _ = try await cloud.api.createFirewallRule(source: source, destination: destination, description: value["description"] as? String) }
        }
        bind("cloudEnrollMachine", registry, reason: reason) { invocation in try enrollMachine(invocation, context) }
    }

    /// `cloud enroll-machine` (CloudMachineEnrollment): authorizes this Mac's key on the machine and
    /// pins its host key, writes the ssh route through the app's tunnel, then peers acpmux to it.
    /// Answers `pending` after 30 s (acpmux's install can take minutes) and keeps going; a rerun
    /// is safe and answers what is done.
    static func enrollMachine(_ invocation: ActionInvocation, _ context: AppActionContext) throws {
        let cloud = context.services.cloud, work = context.services.work, session = try machine(invocation, context)
        let name = invocation["name"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? session.machine.displayName ?? ""
        guard CloudMachineEnrollment.isHostName(name) else { throw ActionFailure(message: CloudStrings.enrollNameInvalid) }
        guard let address = session.machine.address?.ipv4 ?? session.machine.address?.ipv6, CloudMachineEnrollment.isAddress(address) else {
            throw ActionFailure(message: CloudStrings.enrollNoAddress)
        }
        guard session.machine.allows(.exec) else { throw ActionFailure(message: CloudStrings.execUnavailable) }
        guard let binary = cloud.binary, let hub = cloud.hub else { throw ActionFailure(message: CloudStrings.noClient) }
        let keyPath = (invocation["sshKey"]?.stringValue ?? "~/.ssh/id_ed25519.pub").replacingOccurrences(of: "^~(?=/)", with: NSHomeDirectory(), options: .regularExpression)
        // Every path lands in ssh_config, and the cli path in ProxyCommand's shell line.
        let identity = keyPath.hasSuffix(".pub") ? String(keyPath.dropLast(4)) : nil, hubLink = cloud.paths.hubLink
        guard [keyPath, identity ?? "/", hubLink].allSatisfy(CloudMachineEnrollment.isPlainPath) else {
            throw ActionFailure(message: CloudStrings.enrollKeyUnreadable(keyPath))
        }
        guard CloudMachineEnrollment.isPlainPath(binary.path) else { throw ActionFailure(message: CloudStrings.noClient) }
        let machineID = session.machineID, home = FileManager.default.homeDirectoryForCurrentUser
        let registry = "tools/lane-vm-enroll \(name) \(machineID) --address \(address) --apply"
        let keyFlag = invocation["sshKey"]?.stringValue == nil ? "" : " --ssh-key '\(keyPath)'"
        let rerun = "cmux cloud enroll-machine --target machine:\(machineID) --name \(name)\(keyFlag)"
        // A slow run (acpmux's install can take minutes) answers this, with `pending: true`, and goes
        // on; the rerun answers what is done. The step lists are `steps_done` and `steps_pending`
        // so they never meet that flag.
        let pending: [String: ActionResultValue] = [
            "machine_id": .string(machineID), "name": .string(name), "ssh_host": .string(name), "address": .string(address),
            "status": .string("enrolling"), "rerun_command": .string(rerun), "registry_command": .string(registry),
            "steps_done": .array([]), "steps_pending": .array(["ssh-key", "ssh-config", "acpmux-peer", "fleet-registry"].map(ActionResultValue.string)),
        ]
        result("enroll Cloud machine", context, pendingAfter: .seconds(30), pending: pending) {
            let text = try? await work.run(.userBlocking, mayBlock: .files) { try String(blockingContentsOf: URL(fileURLWithPath: keyPath), encoding: .utf8) }
            guard let key = text.flatMap(CloudMachineEnrollment.ed25519Key) else { throw ActionFailure(message: CloudStrings.enrollKeyUnreadable(keyPath)) }
            let enrollment = CloudMachineEnrollment(name: name, machineID: machineID, address: address, publicKey: key)
            let ran = try await cloud.api.exec(machineID, command: enrollment.authorizeCommand, timeoutMs: execTimeoutMs)
            let hostKey = ran.stdout.split(whereSeparator: \.isNewline).last.flatMap { CloudMachineEnrollment.ed25519Key(String($0)) }
            guard ran.exitCode == 0, let hostKey else {
                throw ActionFailure(message: CloudStrings.enrollAuthorizeFailed(String((ran.stderr.isEmpty ? ran.stdout : ran.stderr).suffix(300))))
            }
            _ = try await hub.linkedSocketPath() // the hub runs, and its link points at it
            let marker = cloud.paths.sshRoutesMarker
            let local = try await work.run(.userBlocking, mayBlock: .files) {
                let installed = try enrollment.installOnThisMac(hostKey: hostKey, cli: binary.path, hubLink: hubLink, identityFile: identity, home: home)
                _ = FileManager.checked.createFile(atPath: marker.path, contents: Data(), attributes: [.posixPermissions: 0o600])
                return installed
            }
            var done: [ActionResultValue] = [.string("ssh-key")] + local.done.map(ActionResultValue.string)
            var left = local.pending.map(ActionResultValue.string)
            if local.pending.isEmpty {
                left += await acpmuxPeer(name, cli: HostCLI(binary: binary, environment: SSHService.environment), done: &done).map(ActionResultValue.string)
            } else {
                // `ssh NAME` may still mean another machine here: no acpmux step goes to it.
                left.append(.string("acpmux-peer: after the include, run \(rerun)"))
            }
            return ["machine_id": .string(machineID), "name": .string(name), "ssh_host": .string(name), "address": .string(address),
                    "steps_done": .array(done), "steps_pending": .array(left + [.string("fleet-registry")]), "registry_command": .string(registry),
                    "rerun_command": .string(rerun)]
        }
    }

    /// `acp host enroll NAME` (the Add Machine card's command: install, daemon, the claude and
    /// codex profiles, peer). It installs only this Mac's own platform, so a Linux machine whose
    /// acpmux comes from its image or bootstrap stops at install: then `acp host add NAME` peers
    /// to that daemon, and the profiles stay pending. Answers what is left.
    private static func acpmuxPeer(_ name: String, cli: HostCLI, done: inout [ActionResultValue]) async -> [String] {
        var last = ""
        do {
            for try await line in cli.lines(["acp", "host", "enroll", name, "--name", name, "--harness", "claude", "--harness", "codex", "--json"]) {
                last = line
            }
            done.append(.string("acpmux-enroll"))
            return []
        } catch {
            let why = String((error.localizedDescription.isEmpty ? last : error.localizedDescription).suffix(300))
            // `host add` answers once the first connect settled; the peer list says whether it is up.
            let added = await cli.json(["acp", "host", "add", name, "--json"], deadline: .seconds(60), label: "acp host add")
            let peers = added.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["peers"] as? [[String: Any]]
            let peer = peers?.first { $0["name"] as? String == name }
            guard peer?["connected"] as? Bool == true else {
                return ["acpmux-peer: \((peer?["error"] as? String).map { "added but not connected: \($0)" } ?? why)"]
            }
            done.append(.string("acpmux-peer"))
            return ["harness-profiles: \(why)"]
        }
    }

    private static func networkArgument(_ invocation: ActionInvocation) throws -> String {
        guard let value = invocation["path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { throw ActionFailure(message: CloudStrings.filePathRequired) }
        return value
    }
}
