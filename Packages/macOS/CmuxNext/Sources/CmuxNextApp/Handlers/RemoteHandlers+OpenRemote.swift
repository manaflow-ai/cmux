import CmuxNextActions
import CmuxNextCompat
import CmuxNextDaemon
import Foundation

/// `cmux open-remote <host>` (manaflow-ai/cmux#25092): one idempotent verb that opens a persistent
/// terminal of a connected machine in a tab or a split, or focuses the one a first run made.
extension RemoteHandlers {
    static func bindOpenRemote(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("remote.openRemote", run: { invocation in
            let request: OpenRemoteRequest
            do { request = try OpenRemoteRequest(invocation) } catch let failure as OpenRemoteRequest.Failure {
                throw ActionFailure(message: message(for: failure))
            }
            guard let pane = context.daemonPane(invocation) else { throw ActionFailure.invalidTarget(RefusalStrings.noPaneID(invocation.target?.id ?? "focused")) }
            let machines = context.services.machines
            let known = machines.ssh.map { OpenRemoteMachine(id: $0.machineID, name: $0.host.label, destination: $0.host.destination.description) }
                + machines.cloud.map { OpenRemoteMachine(id: $0.machineID, name: $0.machine.title, destination: "") }
            guard let match = OpenRemoteMachine.match(request.host, in: known) else {
                throw ActionFailure.notFound(RemoteStrings.openRemoteHostNotFound(request.host))
            }
            guard let daemon = machines.daemon(machine: match.id), let session = daemon.identity?.sessionID else {
                throw ActionFailure(message: WorkspaceVerbStrings.machineNotConnected)
            }
            let home = context.services.daemon(for: pane)
            let title = RemoteStrings.terminalOn(context.services.remoteTerminals.sessionName(of: daemon))
            // Idempotent: the tab a first run made, anywhere in the home's workspaces.
            let existing = home.store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).first {
                $0.kind == .remoteTerminal && $0.remote?.sessionID == session
                    && request.matchesTab(name: $0.name, title: $0.displayTitle, defaultTitle: title)
            }
            if let existing {
                if request.focus {
                    registry.perform("tab.focus", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: existing.id), origin: invocation.origin))
                }
                return
            }
            let direction: SplitDirection? = switch request.placement {
            case .tab: nil
            case .right: .right
            case .down: .down
            }
            if let failure = context.services.remoteTerminals.openTerminal(
                on: daemon, in: pane, home: home, cwd: request.cwd, splitting: direction, name: request.attach ?? request.name,
                command: request.cmd, ratio: request.ratio, keepFocus: !request.focus
            ) {
                throw ActionFailure(message: failure.message)
            }
        })
    }

    private static func message(for failure: OpenRemoteRequest.Failure) -> String {
        switch failure {
        case .missingHost: RemoteStrings.noMachine
        case .unsupportedSplit: RemoteStrings.splitRightOrDown
        case .badRatio(let text): RemoteStrings.openRemoteBadRatio(text)
        }
    }
}
