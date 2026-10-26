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
        guard keyPath.hasPrefix("/") else { throw ActionFailure(message: CloudStrings.enrollKeyUnreadable(keyPath)) }
        let machineID = session.machineID, home = FileManager.default.homeDirectoryForCurrentUser
        var pending: [String: ActionResultValue] = ["machine_id": .string(machineID), "name": .string(name), "address": .string(address)]
        pending["status"] = .string("enrolling")
        result("enroll Cloud machine", context, pendingAfter: .seconds(30), pending: pending) {
            let text = try? await work.run(.userBlocking, mayBlock: .files) { try String(blockingContentsOf: URL(fileURLWithPath: keyPath), encoding: .utf8) }
            guard let key = text.flatMap(CloudMachineEnrollment.ed25519Key) else { throw ActionFailure(message: CloudStrings.enrollKeyUnreadable(keyPath)) }
            let enrollment = CloudMachineEnrollment(name: name, machineID: machineID, address: address, publicKey: key)
            let ran = try await cloud.api.exec(machineID, command: enrollment.authorizeCommand, timeoutMs: execTimeoutMs)
            let hostKey = ran.stdout.split(whereSeparator: \.isNewline).last.flatMap { CloudMachineEnrollment.ed25519Key(String($0)) }
            guard ran.exitCode == 0, let hostKey else {
                throw ActionFailure(message: CloudStrings.enrollAuthorizeFailed(String((ran.stderr.isEmpty ? ran.stdout : ran.stderr).suffix(300))))
            }
            _ = try await hub.socketPath() // the hub runs, and its link points at it
            let identity = keyPath.hasSuffix(".pub") ? String(keyPath.dropLast(4)) : nil
            let hubLink = cloud.paths.hubLink
            let local = try await work.run(.userBlocking, mayBlock: .files) {
                try enrollment.installOnThisMac(hostKey: hostKey, cli: binary.path, hubLink: hubLink, identityFile: identity, home: home)
            }
            var done: [ActionResultValue] = [.string("ssh-key")] + local.done.map(ActionResultValue.string)
            var left = local.pending.map(ActionResultValue.string)
            let peer = await acpmuxEnroll(name, cli: HostCLI(binary: binary, environment: SSHService.environment))
            if let peer { left.append(.string("acpmux-peer: \(peer)")) } else { done.append(.string("acpmux-peer")) }
            let registry = "tools/lane-vm-enroll \(name) \(machineID) --address \(address) --apply"
            return ["machine_id": .string(machineID), "name": .string(name), "ssh_host": .string(name), "address": .string(address),
                    "done": .array(done), "pending": .array(left + [.string("fleet-registry")]), "registry_command": .string(registry)]
        }
    }

    /// `acp host enroll NAME` (the Add Machine card's command): nil when it finished, else why not.
    private static func acpmuxEnroll(_ name: String, cli: HostCLI) async -> String? {
        var last = ""
        do {
            for try await line in cli.lines(["acp", "host", "enroll", name, "--name", name, "--harness", "claude", "--harness", "codex", "--json"]) {
                last = line
            }
            return nil
        } catch {
            return String((error.localizedDescription.isEmpty ? last : error.localizedDescription).suffix(300))
        }
    }

    private static func networkArgument(_ invocation: ActionInvocation) throws -> String {
        guard let value = invocation["path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { throw ActionFailure(message: CloudStrings.filePathRequired) }
        return value
    }
}
