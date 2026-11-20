import AppKit
import CmuxNextActions
import CmuxNextCloud
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextHomeEngine
import CmuxNextRemote
import CmuxNextSidebar
import Foundation

/// "Move Chief To…" (remote-groups-DESIGN.md slice 6, chief-migration-DESIGN.md 8a): lists This Mac, the
/// SSH and server remote groups and cmux Cloud (`ChiefMoveTargets`), then runs the bundled
/// `cmux chief move` (one implementation with the CLI and MCP): a dry run whose report the person reads,
/// the move, then `move reach` on the target. The Cloud session token goes through a 0600 file that is
/// deleted when the move ends, never the command line. Each step shows on the Chief's location chip
/// (`AppServices.chiefTeleport`), whose Teleport menu runs this same action.
@MainActor
enum ChiefMoveHandlers {
    static let actionID: ActionID = "chief.moveTo"
    static let rollbackID: ActionID = "chief.moveRollback"

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        // The handler cannot wait: it reads what is known now, and this read answers before a person opens the menu.
        let bundled = context.services.bundledCLI
        Task { _ = await bundled.resolve() } // task-owner: none; one bounded file read whose answer bundled keeps
        CloudHandlers.bind(actionID, registry, reason: { bundled.known == nil ? ChiefMoveStrings.noCLI : nil }) { invocation in
            guard let cli = bundled.known else { throw ActionFailure(message: ChiefMoveStrings.noCLI) }
            let targets = Self.targets(context)
            let interactive = !registry.isCapturingRefusal
            if let wanted = invocation["target"]?.stringValue ?? invocation.target?.id {
                guard let target = targets.first(where: { matches($0, wanted) }) else {
                    throw ActionFailure.invalidTarget(ChiefMoveStrings.unknownTarget(wanted))
                }
                return try start(target, cli: cli, interactive: interactive, registry: registry, context: context)
            }
            guard interactive else { throw ActionFailure.invalidTarget(ChiefMoveStrings.targetRequired) }
            // The machines as a Cmd-Shift-P step; Return runs this again with the picked one.
            registry.ask(actionID, invocation, ActionArgumentAsk(argument: "target"))
        }
        let otherSuggestions = registry.argumentSuggestions
        registry.argumentSuggestions = { source in
            guard source == ActionSuggestions.chiefMoveTargets else { return otherSuggestions?(source) ?? [] }
            return targets(context).map { ActionEnumCase(value: $0.machineID, title: $0.title) }
        }
        bindRollback(into: registry, context: context)
        bindTeleport(context.services.chiefTeleport, registry: registry, context: context)
    }

    /// The list as the app sees its machines now.
    static func targets(_ context: AppActionContext) -> [ChiefMoveTarget] {
        let machines = context.services.machines
        let records = context.services.sidebarDoc.store?.records
        func isRemoteGroup(_ daemon: DaemonService) -> Bool {
            guard let session = daemon.store.registryID else { return false }
            return records?.sections["sec_m_\(session)"]?.hostGroup == true
        }
        var hosts: [ChiefMoveTargets.Host] = machines.ssh.map { session in
            .init(machineID: session.machineID, name: session.host.label, kind: .ssh(destination: session.host.destination.sshArgument),
                  isOnline: session.linkStatus == .connected, isRemoteGroup: isRemoteGroup(session.daemon))
        }
        // A server on this Mac (route `unix`) is This Mac, already the first entry.
        hosts += machines.servers.compactMap { server in
            let destination: String?
            switch server.reach.route {
            case .ssh(let host): destination = host.destination.sshArgument
            case .overlay:
                if case .ssh(let host)? = ServerReach.brainRoute(serverName: server.name) { destination = host.destination.sshArgument }
                else { destination = nil }
            case .unix: return nil
            }
            return .init(machineID: server.machineID, name: server.name, kind: .server(destination: destination),
                         isOnline: server.daemon.connection != nil, isRemoteGroup: isRemoteGroup(server.daemon))
        }
        let cloud = context.services.cloud
        let home = ChiefHome.resolve(tag: context.services.environment.tag).root.path
        return ChiefMoveTargets(localHome: home, hosts: hosts,
                                cloud: cloud.isSignedIn ? .signedIn(staging: !cloud.configuration.isProductionAuth) : .signedOut).targets
    }

    private static func matches(_ target: ChiefMoveTarget, _ wanted: String) -> Bool {
        let lowered = wanted.lowercased()
        return [target.machineID, target.name, target.to ?? ""].contains { $0.lowercased() == lowered }
    }

    private static func start(_ target: ChiefMoveTarget, cli: URL, interactive: Bool, registry: ActionRegistry,
                              context: AppActionContext) throws {
        if let reason = target.disabledReason { throw ActionFailure.invalidTarget(target.title.isEmpty ? "\(reason)" : target.title) }
        guard let to = target.to else { throw ActionFailure.invalidTarget(target.title) }
        guard !context.services.chiefTeleport.phase.isRunning else { throw ActionFailure(message: ChiefMoveStrings.running) }
        registry.track(runner(cli: cli, interactive: interactive, context: context).move(target, to: to))
    }

    /// The move and rollback steps with the app's dialogs and the Cloud session token.
    private static func runner(cli: URL, interactive: Bool, context: AppActionContext) -> ChiefTeleportRunner {
        let window = CloudHandlers.window(context)
        let cloud = context.services.cloud
        return ChiefTeleportRunner(model: context.services.chiefTeleport, cli: cli, interactive: interactive,
                                   writeToken: { try await writeToken(cloud) },
                                   confirm: { title, body, button, identifier in
                                       await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                                           CloudPresenter.confirm(title, body, button: button, identifier: identifier, in: window) {
                                               done.resume(returning: $0)
                                           }
                                       }
                                   },
                                   show: { CloudPresenter.show($0, $1, copyable: true, in: window) })
    }

    /// Roll Back Chief Move (`chief.moveRollback`): `cmux chief move rollback` on the app's Chief home.
    private static func bindRollback(into registry: ActionRegistry, context: AppActionContext) {
        let bundled = context.services.bundledCLI
        let teleport = context.services.chiefTeleport
        func refusal() -> String? {
            if bundled.known == nil { return ChiefMoveStrings.noCLI }
            if teleport.location == .thisMac { return ChiefMoveStrings.notMoved }
            return teleport.phase.isRunning ? ChiefMoveStrings.running : nil
        }
        registry.bindEffect(rollbackID, unavailable: refusal, effect: { _ in
            guard let cli = bundled.known, refusal() == nil else { return .refused(refusal() ?? ChiefMoveStrings.noCLI) }
            return .applied(result: runner(cli: cli, interactive: !registry.isCapturingRefusal, context: context).rollback())
        })
    }

    /// The Teleport menu's picks run `chief.moveTo` and `chief.moveRollback`, never a second path.
    private static func bindTeleport(_ teleport: ChiefTeleportModel, registry: ActionRegistry, context: AppActionContext) {
        teleport.destinations = { targets(context).map(\.teleportDestination) }
        teleport.onMove = { [weak registry] id in
            _ = registry?.perform(actionID, invocation: ActionInvocation(arguments: ["target": .string(id)], origin: .user))
        }
        teleport.onRollback = { [weak registry] in _ = registry?.perform(rollbackID, invocation: ActionInvocation(origin: .user)) }
        // The engine's `move watch` carries out a moved Chief's requests; after a restart nobody else starts it.
        teleport.onMoved = { _ in ChiefMoveWatchLauncher().start(home: teleport.home) }
        teleport.refresh()
    }

    /// The Cloud session token in a 0600 file inside a 0700 folder of its own.
    static func writeToken(_ cloud: CloudService) async throws -> (folder: URL, file: URL) {
        let token = try await cloud.auth.tokens().access
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-chief-move-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let file = dir.appendingPathComponent("session-token")
        guard FileManager.default.createFile(atPath: file.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return (dir, file)
    }
}
