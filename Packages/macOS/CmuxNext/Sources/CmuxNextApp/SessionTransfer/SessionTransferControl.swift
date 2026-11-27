import CmuxNextControl
import CmuxNextSettings

/// Control-socket methods for the local handoff protocol. A sibling build can
/// list records without touching AppKit, then acknowledge each one after it
/// has recreated the terminal or adopted the agent session.
@MainActor
enum SessionTransferControl {
    static func methods(services: AppServices) -> [ControlMethod] {
        [
            .async("session.transfer.list") { [transfer = services.sessionTransfer] call in
                // This Mac's chats, and the acpmux the taker moves them from.
                let (chats, acpmux) = await MainActor.run {
                    (transfer.localChats(), transfer.acpmuxEnvironment().map { (socket: $0.socketPath, home: $0.home.path) })
                }
                // The local daemon's workspaces only: `complete` closes on it.
                let workspaces = call.snapshot.topology.workspaces.filter { $0.machine == nil }
                // Moving a terminal ends what runs in it, so each says whether it idles at its shell.
                let terminals = workspaces.flatMap { $0.screens.flatMap(\.panes).flatMap(\.tabs) }
                    .filter { $0.kind == "terminal" && $0.agentSessionID == nil }.map(\.surface)
                let programs = await transfer.foregroundPrograms(terminals)
                let sessions = workspaces.flatMap { workspace in
                    workspace.screens.flatMap(\.panes).flatMap { pane in
                        pane.tabs.compactMap { tab -> JSONValue? in
                            if let chat = chats[tab.id], let acpmux {
                                return [
                                    "surface": .string(tab.surface),
                                    "workspace": .string(workspace.id),
                                    "kind": "chat",
                                    "title": .string(tab.title),
                                    "cwd": .optional(tab.cwd),
                                    "agent": .optional(chat.harness),
                                    "agent_session": .string(chat.session),
                                    "acpmux_socket": .string(acpmux.socket),
                                    "acpmux_home": .string(acpmux.home),
                                ]
                            }
                            // Local terminals: a remote terminal carries a session id rather than its host.
                            guard tab.kind == "terminal", tab.agentSessionID == nil else { return nil }
                            return [
                                "surface": .string(tab.surface),
                                "workspace": .string(workspace.id),
                                "kind": "terminal",
                                "title": .string(tab.title),
                                "cwd": .optional(tab.cwd),
                                "ssh_target": .null,
                                "command": .null,
                                "agent": .null,
                                "agent_session": .null,
                                // `idle` true: its shell only; false: `foreground_program` runs;
                                // both null: no answer, which a taker treats as busy.
                                "idle": programs[tab.surface].map { JSONValue.bool($0 == nil) } ?? .null,
                                "foreground_program": .optional(programs[tab.surface].flatMap { $0 }),
                            ]
                        }
                    }
                }
                return [
                    "protocol": .string("session-transfer-v1"),
                    "source": .string("cmux-next"),
                    "sessions": .array(sessions),
                ]
            },
            .async("session.transfer.peers") { [transfer = services.sessionTransfer] _ in
                do {
                    let peers = try await transfer.discover()
                    return ["peers": .array(peers.map { peer in
                        ["socket": .string(peer.path), "app": .string(peer.app), "build": .string(peer.build),
                         "tag": .optional(peer.tag), "sessions": .array(peer.items.map(\.json))]
                    })]
                } catch {
                    throw controlError(error)
                }
            }.withDeadline(.fixed(.seconds(60))),
            .async("session.transfer.pull") { [transfer = services.sessionTransfer] call in
                guard let source = call.params["source"]?.stringValue else {
                    throw ControlError.invalidParams("source is required: a peer socket path or tag from session.transfer.peers")
                }
                let ids = Set(call.params["ids"]?.arrayValue?.compactMap(\.stringValue) ?? [])
                // A chat running a turn moves only when its turn may stop.
                let interrupt = call.params["interrupt"]?.boolValue == true
                // A chat whose folder is not here (its failure's `missing_folder`) moves into `cwd`:
                // that one chat only, so no other chat leaves its own folder.
                let cwd = call.params["cwd"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                if cwd != nil, ids.count != 1 {
                    throw ControlError.invalidParams("cwd needs ids naming the one chat to move into it")
                }
                do {
                    return try await transfer.pull(source: source, ids: ids, interrupt: interrupt, cwd: cwd)
                } catch {
                    throw controlError(error)
                }
            }.withDeadline(.fixed(.seconds(300))),
            .async("session.transfer.open") { [transfer = services.sessionTransfer] call in
                let agent = call.params["agent"]?.objectValue
                let workspace = call.params["workspace"]?.objectValue
                guard agent != nil || workspace != nil else { throw ControlError.invalidParams("agent or workspace is required") }
                do {
                    return try await transfer.open(agent: agent, workspace: workspace)
                } catch {
                    throw controlError(error)
                }
            }.withDeadline(.fixed(.seconds(120))),
            .async("session.transfer.complete") { [transfer = services.sessionTransfer] call in
                let surfaces = call.params["surfaces"]?.arrayValue?.compactMap(\.stringValue) ?? []
                guard !surfaces.isEmpty else { throw ControlError.invalidParams("surfaces is required") }
                // `idle_only`: close none if one runs a program now (code `terminal_busy`).
                do {
                    try await transfer.complete(surfaces: surfaces, idleOnly: call.params["idle_only"]?.boolValue == true)
                } catch SessionTransferService.Failure.terminalBusy(let reason) {
                    throw controlError(SessionTransferService.Failure.terminalBusy(reason))
                }
                return ["closed": JSONValue(surfaces.count)]
            }.withDeadline(.fixed(.seconds(30))),
        ]
    }
}

/// A transfer failure as the control error the caller sees.
private nonisolated func controlError(_ error: Error) -> ControlError {
    let code = switch error {
    case SessionTransferService.Failure.noSessions: "not_found"
    case SessionTransferService.Failure.peerRefused: "access_denied"
    case SessionTransferService.Failure.unavailable: "unavailable"
    case SessionTransferService.Failure.missingAgentID: "invalid_params"
    case SessionTransferService.Failure.agentNotOpened: "unavailable"
    case SessionTransferService.Failure.chatNotMoved: "unavailable"
    case SessionTransferService.Failure.chatFolderMissing: "unavailable"
    case SessionTransferService.Failure.chatInChats: "unavailable"
    case SessionTransferService.Failure.sourceAgentsStopped: "unavailable"
    case SessionTransferService.Failure.terminalBusy: SessionTransferService.busyCode
    default: "internal_error"
    }
    return ControlError(code: code, message: SessionTransferService.message(for: error))
}

private extension JSONValue {
    nonisolated static func optional(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }
}
