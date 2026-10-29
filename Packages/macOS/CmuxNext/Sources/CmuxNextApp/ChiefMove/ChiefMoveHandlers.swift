import AppKit
import CmuxNextActions
import CmuxNextCloud
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextHomeEngine
import CmuxNextRemote
import CmuxNextSidebar
import CmuxNextWakeups
import Foundation
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

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
        let auth = context.services.cloud.auth, work = context.services.work
        let title = name(target)
        // Everything the steps need is made here, on main and without I/O: the token file's place (a Cloud target
        // only) and the plan that names it.
        var tokenDir: URL?
        if case .cloud = target.kind {
            tokenDir = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-chief-move-\(UUID().uuidString)")
        }
        let token = tokenDir.map { (dir: $0, file: $0.appendingPathComponent("session-token")) }
        let plan = ChiefMovePlan(to: to, kind: target.kind, targetHome: targetHome, tokenFile: token?.file.path)
        let reach: (URL, [String])? = switch plan.reach {
        case .cli(let arguments): (cli, arguments)
        case .remote(let command): (URL(fileURLWithPath: "/usr/bin/env"), command)
        case .none: nil
        }
        let steps = Steps(cli: cli, dryRun: plan.dryRun, move: plan.move, reach: reach, token: token)
        // R-hop: the steps run off main (ProcessRunner, the token file on the files lane); the confirmation and the
        // end are main-thread tasks of the run's class (userBlocking for the person's move, p06 rule 2).
        let end = registry.completion(on: context.services.mainWork)
        let confirm: @Sendable (String) async -> Bool = { report in
            guard interactive else { return true }
            // A dialog that goes unanswered (or a post that is dropped) is a no.
            return (try? await withOnceContinuation { (done: OnceContinuation<Bool, OnceContinuationError>) in
                end.post(owner: "ChiefMoveHandlers.confirm") {
                    CloudPresenter.confirm(ChiefMoveStrings.confirmTitle(title), report, button: ChiefMoveStrings.move,
                                           identifier: "cmux.dialog.chief.move", in: window) { done.resume(returning: $0) }
                }
            }) ?? false
        }
        registry.track(end.start {
            let ended = await Self.perform(steps, auth: auth, work: work, priority: end.priority, confirm: confirm)
            return await end.apply(owner: "ChiefMoveHandlers.ended", answering: true) {
                Self.finish(ended, title: title, interactive: interactive, window: window)
            }
        })
    }

    /// The commands of one move and its token file's place, made on main.
    nonisolated private struct Steps: Sendable {
        var cli: URL
        var dryRun: [String]
        var move: [String]
        /// The reach probe's executable and arguments; nil when there is no home to probe.
        var reach: (URL, [String])?
        var token: (dir: URL, file: URL)?
    }

    /// How a move ended, decided off main; ``finish(_:title:interactive:window:)`` shows it on main.
    nonisolated private enum Ended: Sendable {
        case tokenFailed(String)
        /// A step failed with its report; after the move started it may have applied.
        case failed(String, mayHaveApplied: Bool)
        case declined
        /// The move's report and the reach probe's.
        case moved(String)
    }

    /// The steps, off main: the token file (Cloud), the dry run, the person's confirmation of its report, the move and
    /// the reach probe. The token file is deleted when they end.
    nonisolated private static func perform(_ steps: Steps, auth: CloudAuth, work: BackgroundWork, priority: WorkPriority,
                                            confirm: @Sendable (String) async -> Bool) async -> Ended {
        defer { if let token = steps.token { try? FileManager.default.removeItem(at: token.dir) } }
        if let token = steps.token {
            do {
                let access = try await auth.tokens().access
                try await work.run(priority, mayBlock: .files) { try writeToken(access, dir: token.dir, file: token.file) }
            } catch {
                return .tokenFailed(String(describing: error))
            }
        }
        let report = await run(steps.cli, steps.dryRun, timeout: .seconds(180))
        guard report.ok else { return .failed(report.text, mayHaveApplied: false) }
        guard await confirm(report.text) else { return .declined }
        let moved = await run(steps.cli, steps.move, timeout: .seconds(1800))
        guard moved.ok else { return .failed(moved.text, mayHaveApplied: true) }
        guard let reach = steps.reach else { return .moved(moved.text) }
        return .moved(moved.text + "\n\n" + (await run(reach.0, reach.1, timeout: .seconds(120))).text)
    }

    /// Shows how the move ended (when a person asked) and returns the run's failure.
    private static func finish(_ ended: Ended, title: String, interactive: Bool, window: NSWindow?) -> ActionWorkFailure? {
        switch ended {
        case .tokenFailed(let error):
            return ActionWorkFailure(ChiefMoveStrings.failedTitle(title) + ": " + error)
        case .failed(let text, let mayHaveApplied):
            if interactive { CloudPresenter.show(ChiefMoveStrings.failedTitle(title), text, copyable: true, in: window) }
            return ActionWorkFailure(text, mayHaveApplied: mayHaveApplied)
        case .declined:
            return nil
        case .moved(let summary):
            if interactive { CloudPresenter.show(ChiefMoveStrings.doneTitle(title), summary, copyable: true, in: window) }
            return nil
        }
    }

    /// The Cloud session token in a 0600 file inside a 0700 folder of its own, written on `work`'s files lane
    /// (the memory import's token file, `ChiefMemoryImportHandlers`). Returns the folder and the file; the caller
    /// deletes the folder when its run ends.
    static func writeToken(_ cloud: CloudService, work: BackgroundWork) async throws -> (URL, URL) {
        let token = try await cloud.auth.tokens().access
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-chief-move-\(UUID().uuidString)")
        let file = dir.appendingPathComponent("session-token")
        try await work.run(.userVisible, mayBlock: .files) { try writeToken(token, dir: dir, file: file) }
        return (dir, file)
    }

    /// The Cloud session token in a 0600 file inside a 0700 folder of its own. Blocking file calls: the files lane only.
    nonisolated private static func writeToken(_ token: String, dir: URL, file: URL) throws {
        try FileManager.checked.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        guard FileManager.checked.createFile(atPath: file.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    nonisolated private struct Output { var ok: Bool; var text: String }

    nonisolated private static func run(_ executable: URL, _ arguments: [String], timeout: Duration) async -> Output {
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
