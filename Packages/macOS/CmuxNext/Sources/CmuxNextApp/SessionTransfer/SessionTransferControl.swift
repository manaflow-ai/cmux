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
                            guard tab.kind == "terminal" || tab.kind == "remote-terminal" || tab.agentSessionID != nil else { return nil }
                            let kind = tab.agentSessionID == nil ? "terminal" : "agent"
                            return [
                                "surface": .string(tab.surface),
                                "workspace": .string(workspace.id),
                                "kind": .string(kind),
                                "title": .string(tab.title),
                                "cwd": .optional(tab.cwd),
                                "ssh_target": .optional(tab.remoteSessionID),
                                "command": .null,
                                "agent": .optional(tab.agent),
                                "agent_session": .optional(tab.agentSessionID),
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
            .async("session.transfer.complete") { call in
                let surfaces = call.params["surfaces"]?.arrayValue?.compactMap(\.stringValue) ?? []
                guard !surfaces.isEmpty else { throw ControlError.invalidParams("surfaces is required") }
                return try await MainActor.run {
                    try await services.sessionTransfer.complete(surfaces: surfaces)
                    return ["closed": JSONValue(surfaces.count)]
                }
            }.withDeadline(.fixed(.seconds(30))),
        ]
    }
}

private extension JSONValue {
    static func optional(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }
}
