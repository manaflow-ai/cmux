import CmuxNextAccounts
import CmuxNextActions
import CmuxNextAgentActivity
import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextCompat
import CmuxNextRemote
import CmuxNextWakeups
import Foundation

/// `cloud deliver-secrets --target machine:<own machine> --names NAME[,NAME…] [--repo OWNER/NAME]`: the
/// same delivery as a Cloud machine's (one receiver, one Keychain store), to an SSH machine
/// or an acpmux peer this Mac reaches over ssh (SSHMachineSecrets). An own machine has no machine config
/// that declares names, so the person names the set; the file it gets holds exactly those.
///
/// The values never cross a daemon link. A chat on a peer asks its own daemon, which never takes a
/// value from another daemon (acpmux `server/secrets.rs`); the person's delivery here is the one way a
/// value reaches that machine, written to its file by the receiver, and its shells and agents read it there.
extension CloudHandlers {
    /// Whether `id` names a Cloud machine (its id, or the `machine_…` resource id of a connected one).
    static func isCloudMachine(_ id: String, _ context: AppActionContext) -> Bool {
        let machines = context.services.machines
        return machines.session(id) != nil || machines.cloud.contains { $0.daemon.identity?.machineResourceID?.rawValue == id }
    }

    /// The SSH machine `id` names: its id, else its one sidebar name or destination.
    static func sshMachine(_ id: String, _ context: AppActionContext) -> SSHMachineSession? {
        let machines = context.services.machines
        if let session = machines.sshSession(id) { return session }
        let wanted = id.lowercased()
        let matches = machines.ssh.filter { session in
            [session.host.label, session.host.destination.description, session.host.destination.displayName,
             session.host.destination.sshArgument].contains { $0.lowercased() == wanted }
        }
        return matches.count == 1 ? matches.first : nil
    }

    /// How this Mac reaches acpmux peer `name` (its daemon's own list, no peer asked).
    enum PeerRoute: Equatable {
        case unknown
        /// A peer reached some other way (a tailnet WebSocket): no ssh for the receiver.
        case noSSH
        case ssh(SSHDestination)
    }

    static func peerRoute(_ name: String, among peers: [AcpmuxPeerList.Peer]) -> PeerRoute {
        guard let peer = peers.first(where: { $0.name.lowercased() == name.lowercased() }) else { return .unknown }
        return peer.url.flatMap(SSHMachineSecrets.destination(peerURL:)).map(PeerRoute.ssh) ?? .noSSH
    }

    /// The delivery lock an own-machine delivery holds; a Cloud machine's waits for it (CloudHandlers+Machine).
    static let ownMachineDeliveryKey = "own-machine"

    static func deliverSecretsToOwnMachine(_ id: String, names: [String]?, repo: String?, _ context: AppActionContext) throws {
        guard let names else { throw ActionFailure(message: CloudStrings.secretNamesRequired) }
        let cloud = context.services.cloud, work = context.services.work
        let ssh = sshMachine(id, context)
        // One own-machine delivery at a time, and none beside a Cloud machine's: names that look different
        // (an ssh config alias, a peer's user@host, a Cloud machine also reached over ssh) can be one
        // account whose file each would replace, and no name here proves otherwise.
        let key = ownMachineDeliveryKey
        guard cloud.deliveringSecrets.isEmpty, cloud.deliveringSecrets.insert(key).inserted else { throw ActionFailure(message: CloudStrings.secretsDeliveryRunning) }
        let check = "cmux cloud deliver-secrets --target machine:\(id) --names \(names.joined(separator: ","))"
        let pending: [String: ActionResultValue] = ["machine": .string(id), "status": .string("delivering"), "check": .string(check)]
        result("deliver secrets", context, pendingAfter: .seconds(30), pending: pending) {
            defer { cloud.deliveringSecrets.remove(key) }
            let destination: SSHDestination
            if let ssh {
                destination = ssh.host.destination
            } else {
                var peers: [AcpmuxPeerList.Peer] = []
                if let socket = AgentLaneStore.shared.socketPath { peers = (try? await AcpmuxPeerList(socketPath: socket).peers()) ?? [] }
                switch peerRoute(id, among: peers) {
                case .unknown: throw ActionFailure.notFound(CloudStrings.unknownMachine(id))
                case .noSSH: throw ActionFailure(message: CloudStrings.secretsNoSSHRoute(id))
                case .ssh(let route): destination = route
                }
            }
            let (items, missing) = try await storedSecrets(names, repo: repo, work: work)
            // The file the machine gets holds exactly what is sent: names with no value here never clear it.
            guard !items.isEmpty else { throw ActionFailure(message: CloudStrings.secretsNoneStored(missing.joined(separator: ", "))) }
            var answer: [String: ActionResultValue] = ["machine": .string(id), "declared": .array(names.map(ActionResultValue.string)),
                                                       "missing": .array(missing.map(ActionResultValue.string)),
                                                       "file": .string(SSHMachineSecrets.envFile),
                                                       "source_line": .string(SSHMachineSecrets.sourceLine)]
            // Always sent: an own machine is one file reachable under several names (an SSH machine,
            // a peer, another alias), so no record here can say what it holds now.
            // Before anything reaches the machine: it may also be a Cloud machine whose file this replaces
            // (even if its answer is lost), so the Cloud ledger goes and the next Cloud delivery sends again.
            let ledgerURL = cloud.paths.root.appendingPathComponent("secret-ledger.json")
            try await work.run(.userBlocking, mayBlock: .files) {
                do { try FileManager.default.removeItem(at: ledgerURL) } catch CocoaError.fileNoSuchFile {}
            }
            let values = try await KeychainSecrets().values(items)
            let word = CloudMachineSecrets.randomHex()
            let link = SSHMachineSecrets.link(to: destination, environment: await SSHService.environment(), word: word)
            let count: Int
            do {
                count = try await CloudMachineSecrets.deliver(values, over: link, receiverAt: SSHMachineSecrets.receiverPath,
                                                              ticketAt: SSHMachineSecrets.ticketPath(word))
            } catch let failed as CloudMachineSecrets.DeliveryFailed {
                throw ActionFailure(message: CloudStrings.secretsNotDelivered(failed.reason))
            } catch let unreachable as SSHMachineSecrets.Unreachable {
                throw ActionFailure(message: CloudStrings.secretsNotDelivered(unreachable.message))
            } catch {
                // Only the kind of failure: no error text near the values reaches a log or the caller.
                throw ActionFailure(message: CloudStrings.secretsNotDelivered(String(describing: type(of: error))))
            }
            answer["status"] = .string("delivered")
            answer["delivered"] = .array(items.map { .string($0.name) })
            answer["written"] = .int(count)
            return answer
        }
    }

    /// `cmux agent deliver-secrets --target agent-chat:<session> --names A,B [--repo OWNER/NAME]`: one chat's
    /// secrets in this Mac's acpmux memory, for that chat's agent only (CmuxNextAccounts `AcpmuxChatSecrets`).
    static func deliverSecretsToChat(_ invocation: ActionInvocation, _ context: AppActionContext) throws {
        let secrets = KeychainSecrets(), repo = try secrets.repo(invocation)
        guard let names = try secrets.names(invocation) else { throw ActionFailure(message: CloudStrings.secretNamesRequired) }
        guard let session = chatSession(invocation, context) else { return context.registry.refuse(.noChat, "agentPane.deliverSecrets") }
        guard let environment = QuitAgents.environment(context.services) else { throw ActionFailure(message: CloudStrings.secretsNotDelivered("acpmux")) }
        let work = context.services.work
        result("deliver chat secrets", context) {
            let (items, missing) = try await storedSecrets(names, repo: repo, work: work)
            guard !items.isEmpty else { throw ActionFailure(message: CloudStrings.secretsNoneStored(missing.joined(separator: ", "))) }
            let applied = try await AcpmuxChatSecrets(environment: environment).give(try await secrets.values(items), to: session)
            return ["session_id": .string(session), "delivered": .array(items.map { .string($0.name) }),
                    "missing": .array(missing.map(ActionResultValue.string)), "applied": .string(applied)]
        }
    }

    /// The acpmux session the run names: an `agent-chat:` target's id, else the targeted or focused agent tab's.
    static func chatSession(_ invocation: ActionInvocation, _ context: AppActionContext) -> String? {
        if let target = invocation.target, target.kind == .agentChat { return target.id.isEmpty ? nil : target.id }
        let scope = context.scope(invocation)
        return (scope.tab?.id.rawValue ?? scope.pane?.currentTabKey).flatMap { context.services.agentTabs.session(of: $0) }
    }

    /// The stored names this build's index (BuildStatePaths: a DEV build's own, the file `cmux cloud secret`
    /// writes) has for `names` in scope `repo`, and the ones it lacks. An unreadable index is refused, never "none".
    static func storedSecrets(_ names: [String], repo: String?, work: BackgroundWork) async throws -> (items: [CloudMachineSecrets.Item], missing: [String]) {
        let indexURL = BuildStatePaths.cloudSecretsIndex(environment: ProcessInfo.processInfo.environment, home: FileManager.default.homeDirectoryForCurrentUser)
        let index = try await work.run(.userBlocking, mayBlock: .files) { CloudMachineSecrets.read(indexURL.path) }
        guard let stored = CloudMachineSecrets.index(from: index) else { throw ActionFailure(message: CloudStrings.secretIndexUnreadable(indexURL.path)) }
        return CloudMachineSecrets.plan(declared: names, repo: repo, index: stored)
    }
}
