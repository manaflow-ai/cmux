import CmuxAgentChat
import CmuxMobileShell
import CmuxMobileShellModel
import Foundation

/// The function tools the orchestrator voice session exposes to its Responses
/// backend, and their execution against the shell store.
///
/// Execution reuses the exact seams the visible UI uses — `mobile.chat.*` for
/// prompts, answers, and history, the workspace-action mutations behind the
/// list rows' context menu, the notification feed store — so voice can do
/// what any on-device surface can, and nothing more. Permission tiers live in
/// ``VoiceToolCatalog``; the session controller gates `destructive` calls on
/// an on-screen approval unless Bypass All Permissions is on.
@MainActor
public struct VoiceOrchestratorToolExecutor {
    private let store: CMUXMobileShellStore

    public init(store: CMUXMobileShellStore) {
        self.store = store
    }

    private static let workspaceParameter = #""workspace":{"type":"string","description":"Workspace name or id"}"#

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
                parametersJSON: #"{"type":"object","properties":{\#(workspaceParameter)},"required":["workspace"]}"#
            ),
            VoiceLiveTool(
                name: "read_agent_messages",
                description: """
                Read the most recent conversation messages of a workspace's \
                coding-agent session, newest last. Use to answer "what did \
                the agent say/do".
                """,
                parametersJSON: #"""
                {"type":"object","properties":{\#(workspaceParameter),\#
                "limit":{"type":"integer","description":"How many recent messages, default 8, max 25"}},\#
                "required":["workspace"]}
                """#
            ),
            VoiceLiveTool(
                name: "read_notifications",
                description: """
                Read the user's recent cmux notifications (agent completions, \
                questions, alerts) across workspaces, newest first.
                """,
                parametersJSON: #"""
                {"type":"object","properties":{"limit":{"type":"integer",\#
                "description":"How many notifications, default 10, max 25"},\#
                "unread_only":{"type":"boolean","description":"Only unread ones, default false"}},\#
                "required":[]}
                """#
            ),
            VoiceLiveTool(
                name: "send_prompt",
                description: """
                Send a prompt or instruction to the coding agent in a \
                workspace. Use after the user confirms what to send.
                """,
                parametersJSON: #"""
                {"type":"object","properties":{\#(workspaceParameter),\#
                "prompt":{"type":"string","description":"The text to send to the agent"}},\#
                "required":["workspace","prompt"]}
                """#
            ),
            VoiceLiveTool(
                name: "answer_agent_question",
                description: """
                Answer a multiple-choice question the coding agent is asking \
                (permission prompts, option pickers) by option number, \
                starting at 1. Read the question first with \
                read_agent_messages.
                """,
                parametersJSON: #"""
                {"type":"object","properties":{\#(workspaceParameter),\#
                "option":{"type":"integer","description":"1-based option number to choose"}},\#
                "required":["workspace","option"]}
                """#
            ),
            VoiceLiveTool(
                name: "interrupt_agent",
                description: """
                Interrupt the running coding agent in a workspace (like \
                pressing Escape). Use when the user asks to stop the agent.
                """,
                parametersJSON: #"{"type":"object","properties":{\#(workspaceParameter)},"required":["workspace"]}"#
            ),
            VoiceLiveTool(
                name: "open_workspace",
                description: "Open a workspace on screen so the user can see it.",
                parametersJSON: #"{"type":"object","properties":{\#(workspaceParameter)},"required":["workspace"]}"#
            ),
            VoiceLiveTool(
                name: "create_workspace",
                description: """
                Create a new empty workspace with one terminal on the \
                connected Mac. Follow up with send_prompt to start work in it.
                """,
                parametersJSON: #"{"type":"object","properties":{},"required":[]}"#
            ),
            VoiceLiveTool(
                name: "create_terminal",
                description: "Create an additional terminal in a workspace.",
                parametersJSON: #"{"type":"object","properties":{\#(workspaceParameter)},"required":["workspace"]}"#
            ),
            VoiceLiveTool(
                name: "rename_workspace",
                description: "Rename a workspace.",
                parametersJSON: #"""
                {"type":"object","properties":{\#(workspaceParameter),\#
                "name":{"type":"string","description":"The new workspace name"}},\#
                "required":["workspace","name"]}
                """#
            ),
            VoiceLiveTool(
                name: "set_workspace_pinned",
                description: "Pin or unpin a workspace in the list.",
                parametersJSON: #"""
                {"type":"object","properties":{\#(workspaceParameter),\#
                "pinned":{"type":"boolean"}},"required":["workspace","pinned"]}
                """#
            ),
            VoiceLiveTool(
                name: "set_workspace_unread",
                description: "Mark a workspace read (unread=false) or unread (unread=true).",
                parametersJSON: #"""
                {"type":"object","properties":{\#(workspaceParameter),\#
                "unread":{"type":"boolean"}},"required":["workspace","unread"]}
                """#
            ),
            VoiceLiveTool(
                name: "mark_all_notifications_read",
                description: "Mark every cmux notification as read.",
                parametersJSON: #"{"type":"object","properties":{},"required":[]}"#
            ),
            VoiceLiveTool(
                name: "create_task",
                description: """
                Start a new task: creates a workspace on the connected Mac \
                running a coding agent on the given prompt, exactly like the \
                app's task composer. Prefer this over create_workspace when \
                the user describes work to do.
                """,
                parametersJSON: #"""
                {"type":"object","properties":{\#
                "prompt":{"type":"string","description":"What the agent should do"},\#
                "directory":{"type":"string","description":"Working directory on the Mac; omit for the last used one"},\#
                "agent":{"type":"string","description":"Agent template: claude, codex, opencode, or shell; omit for the default"},\#
                "name":{"type":"string","description":"Optional workspace name"}},\#
                "required":["prompt"]}
                """#
            ),
            VoiceLiveTool(
                name: "list_computers",
                description: "List the user's paired Macs and which one is connected.",
                parametersJSON: #"{"type":"object","properties":{},"required":[]}"#
            ),
            VoiceLiveTool(
                name: "switch_computer",
                description: "Switch the app to another paired Mac by name.",
                parametersJSON: #"""
                {"type":"object","properties":{"computer":{"type":"string",\#
                "description":"Computer name or id"}},"required":["computer"]}
                """#
            ),
            VoiceLiveTool(
                name: "read_workspace_changes",
                description: """
                Read a workspace's uncommitted git changes: changed files \
                with additions and deletions.
                """,
                parametersJSON: #"{"type":"object","properties":{\#(workspaceParameter)},"required":["workspace"]}"#
            ),
            VoiceLiveTool(
                name: "set_workspace_description",
                description: "Set or clear a workspace's description.",
                parametersJSON: #"""
                {"type":"object","properties":{\#(workspaceParameter),\#
                "description":{"type":"string","description":"New description; empty clears"}},\#
                "required":["workspace","description"]}
                """#
            ),
            VoiceLiveTool(
                name: "set_workspace_color",
                description: """
                Set or clear a workspace's list color. Accepts a color name \
                (red, orange, yellow, green, teal, blue, purple, pink, gray) \
                or a hex value; empty clears.
                """,
                parametersJSON: #"""
                {"type":"object","properties":{\#(workspaceParameter),\#
                "color":{"type":"string"}},"required":["workspace","color"]}
                """#
            ),
            VoiceLiveTool(
                name: "mark_notification_read",
                description: """
                Mark one notification read by the id from read_notifications.
                """,
                parametersJSON: #"""
                {"type":"object","properties":{"notification_id":{"type":"string"}},\#
                "required":["notification_id"]}
                """#
            ),
            VoiceLiveTool(
                name: "open_notification",
                description: """
                Open one notification's workspace on screen, by the id from \
                read_notifications.
                """,
                parametersJSON: #"""
                {"type":"object","properties":{"notification_id":{"type":"string"}},\#
                "required":["notification_id"]}
                """#
            ),
            VoiceLiveTool(
                name: "type_in_terminal",
                description: """
                Type raw text into a workspace's terminal (for shells, REPLs, \
                or TUIs rather than the coding agent). press_return submits it.
                """,
                parametersJSON: #"""
                {"type":"object","properties":{\#(workspaceParameter),\#
                "text":{"type":"string"},\#
                "press_return":{"type":"boolean","description":"Submit with Return, default true"}},\#
                "required":["workspace","text"]}
                """#
            ),
            VoiceLiveTool(
                name: "close_workspace",
                description: """
                Close a workspace on the Mac, ending its terminals and agent \
                sessions. Destructive: requires the user's explicit \
                confirmation.
                """,
                parametersJSON: #"{"type":"object","properties":{\#(workspaceParameter)},"required":["workspace"]}"#
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
        let workspaceQuery = arguments["workspace"] as? String ?? ""
        switch name {
        case "list_workspaces":
            return listWorkspaces()
        case "read_workspace":
            return await readWorkspace(query: workspaceQuery)
        case "read_agent_messages":
            return await readAgentMessages(
                query: workspaceQuery,
                limit: arguments["limit"] as? Int ?? 8
            )
        case "read_notifications":
            return readNotifications(
                limit: arguments["limit"] as? Int ?? 10,
                unreadOnly: arguments["unread_only"] as? Bool ?? false
            )
        case "send_prompt":
            return await sendPrompt(
                query: workspaceQuery,
                prompt: arguments["prompt"] as? String ?? ""
            )
        case "answer_agent_question":
            return await answerAgentQuestion(
                query: workspaceQuery,
                option: arguments["option"] as? Int ?? 0
            )
        case "interrupt_agent":
            return await interruptAgent(query: workspaceQuery)
        case "open_workspace":
            return await openWorkspace(query: workspaceQuery)
        case "create_workspace":
            return createWorkspace()
        case "create_terminal":
            return await createTerminal(query: workspaceQuery)
        case "rename_workspace":
            return await renameWorkspace(
                query: workspaceQuery,
                name: arguments["name"] as? String ?? ""
            )
        case "set_workspace_pinned":
            return await setWorkspacePinned(
                query: workspaceQuery,
                pinned: arguments["pinned"] as? Bool ?? true
            )
        case "set_workspace_unread":
            return await setWorkspaceUnread(
                query: workspaceQuery,
                unread: arguments["unread"] as? Bool ?? false
            )
        case "mark_all_notifications_read":
            return await markAllNotificationsRead()
        case "create_task":
            return await createTask(
                prompt: arguments["prompt"] as? String ?? "",
                directory: arguments["directory"] as? String,
                agent: arguments["agent"] as? String,
                name: arguments["name"] as? String
            )
        case "list_computers":
            return listComputers()
        case "switch_computer":
            return await switchComputer(query: arguments["computer"] as? String ?? "")
        case "read_workspace_changes":
            return await readWorkspaceChanges(query: workspaceQuery)
        case "set_workspace_description":
            return await setWorkspaceDescription(
                query: workspaceQuery,
                description: arguments["description"] as? String ?? ""
            )
        case "set_workspace_color":
            return await setWorkspaceColor(
                query: workspaceQuery,
                color: arguments["color"] as? String ?? ""
            )
        case "mark_notification_read":
            return await markNotificationRead(
                notificationID: arguments["notification_id"] as? String ?? ""
            )
        case "open_notification":
            return await openNotification(
                notificationID: arguments["notification_id"] as? String ?? ""
            )
        case "type_in_terminal":
            return await typeInTerminal(
                query: workspaceQuery,
                text: arguments["text"] as? String ?? "",
                pressReturn: arguments["press_return"] as? Bool ?? true
            )
        case "close_workspace":
            return await closeWorkspace(query: workspaceQuery)
        default:
            return "Unknown tool: \(name)"
        }
    }

    // MARK: - Read tools

    private func listWorkspaces() -> String {
        let workspaces = store.workspaces.prefix(40).map { workspace -> [String: Any] in
            var entry: [String: Any] = [
                "id": workspace.id.rawValue,
                "name": workspace.name,
            ]
            if let machine = workspace.macDisplayName { entry["machine"] = machine }
            if workspace.isPinned { entry["pinned"] = true }
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

    private func readAgentMessages(query: String, limit: Int) async -> String {
        guard let workspace = Self.resolveWorkspace(query, in: store.workspaces) else {
            return Self.unknownWorkspace(query, workspaces: store.workspaces)
        }
        guard let chatSource = store.makeChatEventSource(),
              let sessions = try? await chatSource.sessions(
                workspaceID: workspace.rpcWorkspaceID.rawValue
              ),
              let session = ChatSessionDescriptor.openable(sessions).first
        else {
            return "\(workspace.name) has no readable agent session."
        }
        guard let page = try? await chatSource.history(
            sessionID: session.id,
            beforeSeq: nil,
            limit: max(1, min(limit, 25))
        ) else {
            return "Could not load the conversation for \(workspace.name)."
        }
        let filterOptions = SpeakableTextOptions(speakCodeBlocks: false, maximumCharacters: 320)
        let rows = page.messages.map { message -> [String: Any] in
            var row: [String: Any] = ["from": message.role == .user ? "user" : "agent"]
            switch message.kind {
            case .prose(let prose):
                row["text"] = SpeakableTextFilter.speakableText(
                    from: prose.text, options: filterOptions
                )
            case .thought:
                row["text"] = "(internal reasoning)"
            case .toolUse(let tool):
                row["text"] = "(ran \(tool.toolName): \(tool.summary))"
            case .fileEdit:
                row["text"] = "(edited files)"
            case .terminal:
                row["text"] = "(terminal output)"
            case .question(let question):
                var text = "QUESTION: \(question.prompt)"
                if !question.options.isEmpty {
                    let numbered = question.options.enumerated()
                        .map { "\($0.offset + 1). \($0.element.label)" }
                        .joined(separator: " ")
                    text += " Options: \(numbered)"
                }
                row["text"] = text
            case .permissionRequest:
                row["text"] = "(asked for permission)"
            case .status, .attachment, .unsupported:
                row["text"] = "(other)"
            }
            return row
        }
        return Self.json([
            "workspace": workspace.name,
            "agent_state": Self.describe(session.state),
            "messages": rows,
        ])
    }

    private func readNotifications(limit: Int, unreadOnly: Bool) -> String {
        let items = store.notificationFeedItems(scopedTo: nil)
            .filter { unreadOnly ? !$0.isRead : true }
            .prefix(max(1, min(limit, 25)))
            .map { item -> [String: Any] in
                var row: [String: Any] = [
                    "id": item.notificationID,
                    "title": item.title,
                    "body": String(item.body.prefix(200)),
                    "read": item.isRead,
                ]
                if let subtitle = item.subtitle { row["subtitle"] = subtitle }
                if let workspaceTitle = item.workspaceTitle { row["workspace"] = workspaceTitle }
                row["machine"] = item.macDisplayName
                if let minutes = Self.minutesSince(item.createdAt) {
                    row["minutes_ago"] = minutes
                }
                return row
            }
        guard !items.isEmpty else {
            return unreadOnly ? "No unread notifications." : "No notifications."
        }
        return Self.json(["notifications": Array(items)])
    }

    // MARK: - Act tools

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

    private func answerAgentQuestion(query: String, option: Int) async -> String {
        guard option >= 1 else {
            return "Option numbers start at 1."
        }
        guard let workspace = Self.resolveWorkspace(query, in: store.workspaces) else {
            return Self.unknownWorkspace(query, workspaces: store.workspaces)
        }
        guard let chatSource = store.makeChatEventSource(),
              let sessions = try? await chatSource.sessions(
                workspaceID: workspace.rpcWorkspaceID.rawValue
              ),
              let session = sessions.first(where: { $0.state.needsAttention })
                ?? ChatSessionDescriptor.openable(sessions).first,
              session.state != .ended
        else {
            return "No agent session is waiting for an answer in \(workspace.name)."
        }
        do {
            try await chatSource.answer(optionIndex: option - 1, sessionID: session.id)
            return "Chose option \(option) for the agent in \(workspace.name)."
        } catch {
            return "Failed to answer the agent in \(workspace.name)."
        }
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

    private func openWorkspace(query: String) async -> String {
        guard let workspace = Self.resolveWorkspace(query, in: store.workspaces) else {
            return Self.unknownWorkspace(query, workspaces: store.workspaces)
        }
        await store.openWorkspace(workspace.id)
        return "Opened \(workspace.name) on screen."
    }

    private func createWorkspace() -> String {
        guard store.workspaces.isEmpty == false || store.pairedMacs.isEmpty == false else {
            return "No connected Mac to create a workspace on."
        }
        store.createWorkspace()
        return "Creating a new workspace. It will appear in the list in a moment; read the list again to get its name."
    }

    private func createTerminal(query: String) async -> String {
        guard let workspace = Self.resolveWorkspace(query, in: store.workspaces) else {
            return Self.unknownWorkspace(query, workspaces: store.workspaces)
        }
        store.createTerminal(in: workspace.id)
        return "Creating a new terminal in \(workspace.name)."
    }

    private func renameWorkspace(query: String, name: String) async -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "No new name was provided." }
        guard let workspace = Self.resolveWorkspace(query, in: store.workspaces) else {
            return Self.unknownWorkspace(query, workspaces: store.workspaces)
        }
        switch await store.renameWorkspace(id: workspace.id, title: trimmed) {
        case .success:
            return "Renamed \(workspace.name) to \(trimmed)."
        case .failure:
            return "The Mac declined renaming \(workspace.name)."
        }
    }

    private func setWorkspacePinned(query: String, pinned: Bool) async -> String {
        guard let workspace = Self.resolveWorkspace(query, in: store.workspaces) else {
            return Self.unknownWorkspace(query, workspaces: store.workspaces)
        }
        switch await store.setWorkspacePinned(id: workspace.id, pinned) {
        case .success:
            return pinned ? "Pinned \(workspace.name)." : "Unpinned \(workspace.name)."
        case .failure:
            return "The Mac declined changing the pin for \(workspace.name)."
        }
    }

    private func setWorkspaceUnread(query: String, unread: Bool) async -> String {
        guard let workspace = Self.resolveWorkspace(query, in: store.workspaces) else {
            return Self.unknownWorkspace(query, workspaces: store.workspaces)
        }
        switch await store.setWorkspaceUnread(id: workspace.id, unread) {
        case .success:
            return unread
                ? "Marked \(workspace.name) as unread."
                : "Marked \(workspace.name) as read."
        case .failure:
            return "The Mac declined changing the read state of \(workspace.name)."
        }
    }

    private func markAllNotificationsRead() async -> String {
        await store.markAllNotificationFeedItemsRead()
        return "Marked all notifications read."
    }

    /// Start a real task through the same pipeline as the task composer:
    /// template + prompt composed into the agent launch command, submitted to
    /// the connected Mac.
    private func createTask(
        prompt: String,
        directory: String?,
        agent: String?,
        name: String?
    ) async -> String {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return "No task prompt was provided." }
        guard let macDeviceID = store.connectedMacDeviceID else {
            return "No connected Mac to start a task on."
        }
        guard let templateStore = store.taskTemplateStore else {
            return "Task templates are unavailable on this device."
        }
        let templates = templateStore.listTemplates()
        let template: MobileTaskTemplate?
        if let agent, !agent.isEmpty {
            let needle = agent.lowercased()
            template = templates.first {
                $0.builtInKind?.rawValue.lowercased() == needle
                    || $0.name.lowercased() == needle
                    || $0.name.lowercased().contains(needle)
            }
        } else {
            template = templateStore.lastTemplateID()
                .flatMap { id in templates.first { $0.id == id } }
                ?? templates.first { !$0.isPlainShell }
                ?? templates.first
        }
        guard let template else {
            let names = templates.map(\.name).joined(separator: ", ")
            return agent.map { "No agent template matches \"\($0)\". Available: \(names)." }
                ?? "No task templates are available."
        }
        let resolvedDirectory = Self.nonEmpty(directory)
            ?? templateStore.lastDirectory(macDeviceID: macDeviceID)
            ?? template.defaultDirectory
        guard let resolvedDirectory else {
            return "No working directory: tell me which directory on the Mac to use."
        }
        let composition = MobileTaskCommandComposer().compose(
            template: template,
            prompt: trimmedPrompt
        )
        let spec = MobileWorkspaceCreateSpec(
            title: Self.nonEmpty(name) ?? composition.title,
            workingDirectory: resolvedDirectory,
            initialCommand: composition.initialCommand,
            initialEnv: composition.initialEnv.isEmpty ? nil : composition.initialEnv,
            operationID: UUID()
        )
        switch await store.submitTaskComposer(
            macDeviceID: macDeviceID,
            instanceTag: store.connectedMacInstanceTag,
            spec: spec
        ) {
        case .success:
            let title = spec.title ?? "the new task"
            return "Started \(template.name) on \"\(title)\" in \(resolvedDirectory)."
        case .failure:
            return "The Mac declined creating the task."
        }
    }

    private func listComputers() -> String {
        let connectedID = store.connectedMacDeviceID
        let computers = store.pairedMacs.prefix(20).map { mac -> [String: Any] in
            var row: [String: Any] = [
                "id": mac.macDeviceID,
                "name": mac.customName ?? mac.displayName ?? mac.macDeviceID,
            ]
            if let tag = mac.instanceTag { row["instance"] = tag }
            if mac.macDeviceID == connectedID { row["connected"] = true }
            if let minutes = Self.minutesSince(mac.lastSeenAt) {
                row["minutes_since_seen"] = minutes
            }
            return row
        }
        guard !computers.isEmpty else { return "No paired computers." }
        return Self.json(["computers": Array(computers)])
    }

    private func switchComputer(query: String) async -> String {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return "No computer was named." }
        let macs = store.pairedMacs
        let match = macs.first { $0.macDeviceID.lowercased() == needle }
            ?? macs.first { ($0.customName ?? $0.displayName)?.lowercased() == needle }
            ?? Self.uniqueMatch(macs, where: { ($0.customName ?? $0.displayName)?.lowercased().contains(needle) == true })
        guard let match else {
            let names = macs.compactMap { $0.customName ?? $0.displayName }.joined(separator: ", ")
            return "No computer matches \"\(query)\". Paired computers: \(names)."
        }
        let displayName = match.customName ?? match.displayName ?? match.macDeviceID
        let switched = await store.switchToMac(
            macDeviceID: match.macDeviceID,
            instanceTag: match.instanceTag
        )
        return switched
            ? "Switched to \(displayName)."
            : "Could not connect to \(displayName)."
    }

    private func readWorkspaceChanges(query: String) async -> String {
        guard let workspace = Self.resolveWorkspace(query, in: store.workspaces) else {
            return Self.unknownWorkspace(query, workspaces: store.workspaces)
        }
        guard let response = try? await store.fetchChangedFiles(
            workspaceID: workspace.rpcWorkspaceID.rawValue
        ) else {
            return "Could not read changes for \(workspace.name); the Mac may not support it or is unreachable."
        }
        guard !response.files.isEmpty else {
            return "\(workspace.name) has no uncommitted changes."
        }
        let files = response.files.prefix(30).map { file -> [String: Any] in
            [
                "file": file.path.split(separator: "/").suffix(2).joined(separator: "/"),
                "status": String(describing: file.status),
                "additions": file.additions,
                "deletions": file.deletions,
            ]
        }
        return Self.json([
            "workspace": workspace.name,
            "files_changed": response.files.count,
            "files": Array(files),
        ])
    }

    private func setWorkspaceDescription(query: String, description: String) async -> String {
        guard let workspace = Self.resolveWorkspace(query, in: store.workspaces) else {
            return Self.unknownWorkspace(query, workspaces: store.workspaces)
        }
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        switch await store.setWorkspaceDescription(
            id: workspace.id,
            trimmed.isEmpty ? nil : trimmed
        ) {
        case .success:
            return trimmed.isEmpty
                ? "Cleared the description of \(workspace.name)."
                : "Set the description of \(workspace.name)."
        case .failure:
            return "The Mac declined changing the description of \(workspace.name)."
        }
    }

    /// Spoken color names mapped to the workspace palette; hex passes through.
    static let spokenColors: [String: String] = [
        "red": "#FF3B30", "orange": "#FF9500", "yellow": "#FFCC00",
        "green": "#34C759", "teal": "#30B0C7", "blue": "#007AFF",
        "purple": "#AF52DE", "pink": "#FF2D55", "gray": "#8E8E93",
        "grey": "#8E8E93",
    ]

    private func setWorkspaceColor(query: String, color: String) async -> String {
        guard let workspace = Self.resolveWorkspace(query, in: store.workspaces) else {
            return Self.unknownWorkspace(query, workspaces: store.workspaces)
        }
        let trimmed = color.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let resolved: String?
        if trimmed.isEmpty {
            resolved = nil
        } else if let named = Self.spokenColors[trimmed] {
            resolved = named
        } else if trimmed.hasPrefix("#") || trimmed.range(
            of: "^[0-9a-f]{6}$", options: .regularExpression
        ) != nil {
            resolved = trimmed.hasPrefix("#") ? trimmed : "#\(trimmed)"
        } else {
            let names = Self.spokenColors.keys.sorted().joined(separator: ", ")
            return "Unknown color \"\(color)\". Use one of: \(names), or a hex value."
        }
        switch await store.setWorkspaceColor(id: workspace.id, resolved) {
        case .success:
            return resolved == nil
                ? "Cleared the color of \(workspace.name)."
                : "Colored \(workspace.name)."
        case .failure:
            return "The Mac declined changing the color of \(workspace.name)."
        }
    }

    private func markNotificationRead(notificationID: String) async -> String {
        guard let item = store.notificationFeedItems(scopedTo: nil)
            .first(where: { $0.notificationID == notificationID })
        else {
            return "No notification with that id; read the notifications again for current ids."
        }
        await store.markNotificationFeedItemRead(item)
        return "Marked \"\(item.title)\" read."
    }

    private func openNotification(notificationID: String) async -> String {
        guard let item = store.notificationFeedItems(scopedTo: nil)
            .first(where: { $0.notificationID == notificationID })
        else {
            return "No notification with that id; read the notifications again for current ids."
        }
        await store.openNotificationFeedItem(item)
        return "Opened \"\(item.title)\" on screen."
    }

    private func typeInTerminal(query: String, text: String, pressReturn: Bool) async -> String {
        guard !text.isEmpty else { return "No text was provided." }
        guard let workspace = Self.resolveWorkspace(query, in: store.workspaces) else {
            return Self.unknownWorkspace(query, workspaces: store.workspaces)
        }
        guard let terminal = workspace.terminals.first(where: \.isReady)
            ?? workspace.terminals.first
        else {
            return "\(workspace.name) has no terminal."
        }
        let delivered: Bool
        if pressReturn {
            delivered = await store.sendTerminalPaste(
                text, workspaceID: workspace.id, terminalID: terminal.id
            )
        } else {
            delivered = await store.sendTerminalInput(
                text, workspaceID: workspace.id, terminalID: terminal.id
            )
        }
        return delivered
            ? "Typed into \(terminal.name) in \(workspace.name)."
            : "Could not reach the terminal in \(workspace.name)."
    }

    // MARK: - Destructive tools

    private func closeWorkspace(query: String) async -> String {
        guard let workspace = Self.resolveWorkspace(query, in: store.workspaces) else {
            return Self.unknownWorkspace(query, workspaces: store.workspaces)
        }
        switch await store.closeWorkspace(id: workspace.id) {
        case .success:
            return "Closed \(workspace.name)."
        case .failure:
            return "The Mac declined closing \(workspace.name)."
        }
    }

    // MARK: - Helpers

    /// Resolve a spoken workspace reference: exact id, then exact name, then
    /// unique substring match (all case-insensitive).
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

    /// Human-readable target for the destructive-approval card: the resolved
    /// workspace name when the arguments name one, else nil.
    func approvalTarget(forTool name: String, argumentsJSON: String) -> String? {
        guard let raw = VoiceToolCatalog.approvalSummary(
            forTool: name, argumentsJSON: argumentsJSON
        ) else { return nil }
        return Self.resolveWorkspace(raw, in: store.workspaces)?.name ?? raw
    }

    /// The trimmed string when it has content, else nil.
    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// The single element satisfying `predicate`, or nil when zero or many do
    /// (an ambiguous spoken reference must not act on a guess).
    private static func uniqueMatch<Element>(
        _ elements: [Element],
        where predicate: (Element) -> Bool
    ) -> Element? {
        let matches = elements.filter(predicate)
        return matches.count == 1 ? matches.first : nil
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
