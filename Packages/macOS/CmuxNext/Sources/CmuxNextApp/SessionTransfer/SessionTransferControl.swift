import CmuxNextControl
import CmuxNextSettings

/// Control-socket methods for the local handoff protocol. A sibling build can
/// list records without touching AppKit, then acknowledge each one after it
/// has recreated the terminal or adopted the agent session.
@MainActor
enum SessionTransferControl {
    static func methods(services: AppServices) -> [ControlMethod] {
        [
            .snapshot("session.transfer.list") { call in
                let sessions = call.snapshot.topology.workspaces.flatMap { workspace in
                    workspace.screens.flatMap(\.panes).flatMap { pane in
                        pane.tabs.compactMap { tab -> JSONValue? in
                            // Local terminals only: a cmux-next agent chat knows its acpmux
                            // session, not the harness's own id an adopt needs, and a
                            // remote terminal carries a session id rather than its host.
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
                let source = call.params["source"]?.stringValue
                let ids = Set(call.params["ids"]?.arrayValue?.compactMap(\.stringValue) ?? [])
                do {
                    return try await transfer.pull(source: source, ids: ids)
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
                try await transfer.complete(surfaces: surfaces)
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
    default: "internal_error"
    }
    return ControlError(code: code, message: SessionTransferService.message(for: error))
}

private extension JSONValue {
    nonisolated static func optional(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }
}
