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
/// deleted when the move ends, never the command line.
@MainActor
enum ChiefMoveHandlers {
    static let actionID: ActionID = "chief.moveTo"

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let cli: @MainActor () -> URL? = { LocalServerSource.bundledCLI() }
        CloudHandlers.bind(actionID, registry, reason: { cli() == nil ? ChiefMoveStrings.noCLI : nil }) { invocation in
            guard let cli = cli() else { throw ActionFailure(message: ChiefMoveStrings.noCLI) }
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
            return targets(context).map { ActionEnumCase(value: $0.machineID, title: label($0)) }
        }
    }

    /// The list as the app sees its machines now.
    static func targets(_ context: AppActionContext) -> [ChiefMoveTarget] {
        let machines = context.services.machines
        let records = SidebarDocStore.current?.records
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

    private static func name(_ target: ChiefMoveTarget) -> String {
        switch target.kind {
        case .local: WorkspaceVerbStrings.thisMac
        case .cloud: ChiefMoveStrings.cloud
        case .ssh, .server: target.name
        }
    }

    private static func label(_ target: ChiefMoveTarget) -> String {
        switch target.disabledReason {
        case nil: name(target)
        case .offline: ChiefMoveStrings.offline(name(target))
        case .noSSHRoute: ChiefMoveStrings.noSSHRoute(name(target))
        case .signInNeeded: ChiefMoveStrings.signIn(name(target))
        }
    }

    private static func matches(_ target: ChiefMoveTarget, _ wanted: String) -> Bool {
        let lowered = wanted.lowercased()
        return [target.machineID, target.name, target.to ?? ""].contains { $0.lowercased() == lowered }
    }

    private static func start(_ target: ChiefMoveTarget, cli: URL, interactive: Bool, registry: ActionRegistry,
                              context: AppActionContext) throws {
        if let reason = target.disabledReason { throw ActionFailure.invalidTarget(label(target).isEmpty ? "\(reason)" : label(target)) }
        guard let to = target.to else { throw ActionFailure.invalidTarget(label(target)) }
        let targetHome = ChiefMovePlan.targetHome(home: ChiefHome.resolve(tag: context.services.environment.tag).root.path,
                                                  userHome: FileManager.default.homeDirectoryForCurrentUser.path)
        let window = CloudHandlers.window(context)
        let cloud = context.services.cloud
        let title = name(target)
        let work: ActionWork = Task {
            var tokenDir: URL?
            defer { if let tokenDir { try? FileManager.default.removeItem(at: tokenDir) } }
            var tokenFile: String?
            if case .cloud = target.kind {
                do {
                    let (dir, file) = try await writeToken(cloud)
                    (tokenDir, tokenFile) = (dir, file.path)
                } catch {
                    return ActionWorkFailure(ChiefMoveStrings.failedTitle(title) + ": " + String(describing: error))
                }
            }
            let plan = ChiefMovePlan(to: to, kind: target.kind, targetHome: targetHome, tokenFile: tokenFile)
            let report = await run(cli, plan.dryRun, timeout: .seconds(180))
            guard report.ok else {
                if interactive { CloudPresenter.show(ChiefMoveStrings.failedTitle(title), report.text, copyable: true, in: window) }
                return ActionWorkFailure(report.text)
            }
            if interactive {
                let go = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                    CloudPresenter.confirm(ChiefMoveStrings.confirmTitle(title), report.text, button: ChiefMoveStrings.move,
                                           identifier: "cmux.dialog.chief.move", in: window) { done.resume(returning: $0) }
                }
                guard go else { return nil }
            }
            let moved = await run(cli, plan.move, timeout: .seconds(1800))
            guard moved.ok else {
                if interactive { CloudPresenter.show(ChiefMoveStrings.failedTitle(title), moved.text, copyable: true, in: window) }
                return ActionWorkFailure(moved.text, mayHaveApplied: true)
            }
            var summary = moved.text
            switch plan.reach {
            case .cli(let arguments): summary += "\n\n" + (await run(cli, arguments, timeout: .seconds(120))).text
            case .remote(let command): summary += "\n\n" + (await run(URL(fileURLWithPath: "/usr/bin/env"), command, timeout: .seconds(120))).text
            case .none: break
            }
            if interactive { CloudPresenter.show(ChiefMoveStrings.doneTitle(title), summary, copyable: true, in: window) }
            return nil
        }
        registry.track(work)
    }

    /// The Cloud session token in a 0600 file inside a 0700 folder of its own.
    static func writeToken(_ cloud: CloudService) async throws -> (URL, URL) {
        let token = try await cloud.auth.tokens().access
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-chief-move-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let file = dir.appendingPathComponent("session-token")
        guard FileManager.default.createFile(atPath: file.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return (dir, file)
    }

    private struct Output { var ok: Bool; var text: String }

    private static func run(_ executable: URL, _ arguments: [String], timeout: Duration) async -> Output {
        do {
            let result = try await ProcessRunner.run(executable: executable, arguments: arguments, environment: nil,
                                                     timeout: timeout, clock: ContinuousClock())
            let text = [result.stdout, result.stderr].map { String(decoding: $0, as: UTF8.self) }
                .filter { !$0.isEmpty }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return Output(ok: result.status == 0, text: text)
        } catch {
            return Output(ok: false, text: String(describing: error))
        }
    }
}
