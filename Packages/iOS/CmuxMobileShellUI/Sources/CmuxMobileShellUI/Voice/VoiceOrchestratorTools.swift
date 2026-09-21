import CmuxAgentChat
import CmuxMobileShell
import CmuxMobileShellModel
import Foundation

/// The function tools the orchestrator voice session exposes to its Responses
/// backend, and their execution against the shell store.
///
/// Execution reuses the exact seams the visible UI uses — `mobile.chat.send`
/// for prompts (with explicit terminal input as the fallback), the aggregated
/// `workspaces` list for status — so voice can do what any on-device surface
/// can, and nothing more.
@MainActor
public struct VoiceOrchestratorToolExecutor {
    private let store: CMUXMobileShellStore

    public init(store: CMUXMobileShellStore) {
        self.store = store
    }

    /// Tool declarations for the session config.
    public static var tools: [VoiceLiveTool] {
        [
            VoiceLiveTool(
                name: "list_workspaces",
                description: """
                List the user's cmux workspaces across connected Macs, with \
                unread state, last activity, and a one-line preview of the \
                latest agent output.
                """,
                parametersJSON: #"{"type":"object","properties":{},"required":[]}"#
            ),
            VoiceLiveTool(
                name: "read_workspace",
                description: """
                Read one workspace in more detail: its latest activity \
                preview, terminals, and the state of its coding-agent \
                sessions (working, waiting for input, idle).
                """,
                parametersJSON: #"""
                {"type":"object","properties":{"workspace":{"type":"string",\#
                "description":"Workspace name or id, as spoken by the user"}},\#
                "required":["workspace"]}
                """#
            ),
            VoiceLiveTool(
                name: "send_prompt",
                description: """
                Send a prompt or instruction to the coding agent in a \
                workspace. Use after the user confirms what to send.
                """,
                parametersJSON: #"""
                {"type":"object","properties":{"workspace":{"type":"string",\#
                "description":"Workspace name or id"},"prompt":{"type":"string",\#
                "description":"The text to send to the agent"}},\#
                "required":["workspace","prompt"]}
                """#
            ),
            VoiceLiveTool(
                name: "interrupt_agent",
                description: """
                Interrupt the running coding agent in a workspace (like \
                pressing Escape). Use when the user asks to stop the agent.
                """,
                parametersJSON: #"""
                {"type":"object","properties":{"workspace":{"type":"string",\#
                "description":"Workspace name or id"}},"required":["workspace"]}
                """#
            ),
        ]
    }

    /// Execute one tool call and return the output string handed back to the
    /// Responses backend. Never throws: failures return a spoken-friendly
    /// explanation instead, so the conversation can continue.
    public func execute(name: String, argumentsJSON: String) async -> String {
        let arguments = (try? JSONSerialization.jsonObject(
            with: Data(argumentsJSON.utf8)
        )) as? [String: Any] ?? [:]
        switch name {
        case "list_workspaces":
            return listWorkspaces()
        case "read_workspace":
            return await readWorkspace(query: arguments["workspace"] as? String ?? "")
        case "send_prompt":
            return await sendPrompt(
                query: arguments["workspace"] as? String ?? "",
                prompt: arguments["prompt"] as? String ?? ""
            )
        case "interrupt_agent":
            return await interruptAgent(query: arguments["workspace"] as? String ?? "")
        default:
            return "Unknown tool: \(name)"
        }
    }

    // MARK: - Tools

    private func listWorkspaces() -> String {
        let workspaces = store.workspaces.prefix(40).map { workspace -> [String: Any] in
            var entry: [String: Any] = [
                "id": workspace.id.rawValue,
                "name": workspace.name,
            ]
            if let machine = workspace.macDisplayName { entry["machine"] = machine }
            if workspace.hasUnread {
                entry["unread"] = workspace.unreadCount ?? 1
            }
            if let preview = workspace.previewText, !preview.isEmpty {
                entry["preview"] = String(preview.prefix(200))
            }
            if let minutes = Self.minutesSince(workspace.lastActivityAt) {
                entry["minutes_since_activity"] = minutes
            }
            return entry
        }
        guard !workspaces.isEmpty else {
            return "No workspaces are available. The user may not be connected to a Mac."
        }
        return Self.json(["workspaces": Array(workspaces)])
    }

    private func readWorkspace(query: String) async -> String {
        guard let workspace = Self.resolveWorkspace(query, in: store.workspaces) else {
            return Self.unknownWorkspace(query, workspaces: store.workspaces)
        }
        var detail: [String: Any] = [
            "id": workspace.id.rawValue,
            "name": workspace.name,
        ]
        if let preview = workspace.previewText { detail["latest_output_preview"] = preview }
        if let minutes = Self.minutesSince(workspace.lastActivityAt) {
            detail["minutes_since_activity"] = minutes
        }
        detail["terminals"] = workspace.terminals.map(\.name)
        if let sessions = try? await store.makeChatEventSource()?
            .sessions(workspaceID: workspace.rpcWorkspaceID.rawValue) {
            detail["agent_sessions"] = sessions.map { session -> [String: Any] in
                var entry: [String: Any] = ["state": Self.describe(session.state)]
                if let title = session.title { entry["title"] = title }
                return entry
            }
        }
        return Self.json(detail)
    }

    private func sendPrompt(query: String, prompt: String) async -> String {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "No prompt text was provided."
        }
        guard let workspace = Self.resolveWorkspace(query, in: store.workspaces) else {
            return Self.unknownWorkspace(query, workspaces: store.workspaces)
        }
        // Preferred path: the agent-chat send, which injects into the
        // session's own terminal on the Mac. Only sessions on the currently
        // connected Mac are reachable here; the terminal fallback below uses
        // the per-workspace mutation target, which also covers secondary Macs.
        if let chatSource = store.makeChatEventSource(),
           let sessions = try? await chatSource.sessions(
            workspaceID: workspace.rpcWorkspaceID.rawValue
           ),
           let session = ChatSessionDescriptor.openable(sessions).first,
           session.state != .ended {
            do {
                try await chatSource.send(text: prompt, attachments: [], sessionID: session.id)
                return "Sent to the agent in \(workspace.name)."
            } catch {
                // Fall through to the terminal path.
            }
        }
        if let terminal = workspace.terminals.first(where: \.isReady) ?? workspace.terminals.first {
            let delivered = await store.sendTerminalPaste(
                prompt,
                workspaceID: workspace.id,
                terminalID: terminal.id
            )
            if delivered {
                return "Typed into terminal \(terminal.name) in \(workspace.name)."
            }
        }
        return "Could not deliver the prompt: \(workspace.name) has no reachable agent session or terminal."
    }

    private func interruptAgent(query: String) async -> String {
        guard let workspace = Self.resolveWorkspace(query, in: store.workspaces) else {
            return Self.unknownWorkspace(query, workspaces: store.workspaces)
        }
        guard let chatSource = store.makeChatEventSource(),
              let sessions = try? await chatSource.sessions(
                workspaceID: workspace.rpcWorkspaceID.rawValue
              ),
              let running = sessions.first(where: { descriptor in
                  if case .working = descriptor.state { return true }
                  return false
              }) ?? ChatSessionDescriptor.openable(sessions).first,
              running.state != .ended
        else {
            return "No running agent session found in \(workspace.name)."
        }
        do {
            try await chatSource.interrupt(sessionID: running.id, hard: false)
            return "Interrupted the agent in \(workspace.name)."
        } catch {
            return "Failed to interrupt the agent in \(workspace.name)."
        }
    }

    // MARK: - Helpers

    /// Resolve a spoken workspace reference: exact id, then exact name, then
    /// unique prefix/substring match (all case-insensitive).
    static func resolveWorkspace(
        _ query: String,
        in workspaces: [MobileWorkspacePreview]
    ) -> MobileWorkspacePreview? {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return nil }
        if let byID = workspaces.first(where: { $0.id.rawValue.lowercased() == needle }) {
            return byID
        }
        if let byName = workspaces.first(where: { $0.name.lowercased() == needle }) {
            return byName
        }
        let contains = workspaces.filter { $0.name.lowercased().contains(needle) }
        return contains.count == 1 ? contains.first : nil
    }

    private static func unknownWorkspace(
        _ query: String,
        workspaces: [MobileWorkspacePreview]
    ) -> String {
        let names = workspaces.prefix(15).map(\.name).joined(separator: ", ")
        return "No workspace matches \"\(query)\". Available workspaces: \(names)."
    }

    private static func describe(_ state: ChatAgentState) -> String {
        switch state {
        case .idle: return "idle"
        case .working: return "working"
        case .needsInput: return "waiting for the user"
        case .ended: return "ended"
        }
    }

    private static func minutesSince(_ date: Date?) -> Int? {
        guard let date else { return nil }
        return max(0, Int(Date().timeIntervalSince(date) / 60))
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
