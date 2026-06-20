import Foundation

struct OfflineAgentNoteRecord: Codable, Equatable {
    var id: String
    var text: String
    var agent: String?
    var cwd: String?
    var workspaceId: String?
    var surfaceId: String?
    var createdAt: TimeInterval
    var flushedAt: TimeInterval?
}

struct OfflineAgentNotesState: Codable, Equatable {
    var version: Int = 1
    var notes: [OfflineAgentNoteRecord] = []
}

final class OfflineAgentNotesStore {
    private static let defaultStorePath = "~/.cmuxterm/offline-agent-notes.json"

    let storeURL: URL

    private let fileManager: FileManager
    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) {
        if let overridePath = Self.nonEmpty(environment["CMUX_OFFLINE_AGENT_NOTES_PATH"]) {
            self.storeURL = URL(fileURLWithPath: NSString(string: overridePath).expandingTildeInPath)
        } else {
            self.storeURL = URL(fileURLWithPath: NSString(string: Self.defaultStorePath).expandingTildeInPath)
        }
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func add(
        text: String,
        agent: String?,
        cwd: String?,
        workspaceId: String?,
        surfaceId: String?,
        now: Date = Date()
    ) throws -> OfflineAgentNoteRecord {
        let note = OfflineAgentNoteRecord(
            id: UUID().uuidString.lowercased(),
            text: text,
            agent: Self.nonEmpty(agent),
            cwd: Self.nonEmpty(cwd),
            workspaceId: Self.nonEmpty(workspaceId),
            surfaceId: Self.nonEmpty(surfaceId),
            createdAt: now.timeIntervalSince1970,
            flushedAt: nil
        )
        var state = try load()
        state.notes.append(note)
        try save(state)
        return note
    }

    func notes(includeFlushed: Bool = false, agent: String? = nil) throws -> [OfflineAgentNoteRecord] {
        let normalizedAgent = Self.nonEmpty(agent)?.lowercased()
        return try load().notes
            .filter { includeFlushed || $0.flushedAt == nil }
            .filter { note in
                guard let normalizedAgent else { return true }
                return note.agent?.lowercased() == normalizedAgent
            }
            .sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.id < rhs.id
                }
                return lhs.createdAt < rhs.createdAt
            }
    }

    func clear(includeFlushed: Bool = false, agent: String? = nil) throws -> Int {
        let normalizedAgent = Self.nonEmpty(agent)?.lowercased()
        var state = try load()
        let before = state.notes.count
        state.notes.removeAll { note in
            if !includeFlushed, note.flushedAt != nil {
                return false
            }
            if let normalizedAgent {
                return note.agent?.lowercased() == normalizedAgent
            }
            return true
        }
        try save(state)
        return before - state.notes.count
    }

    func markFlushed(ids: Set<String>, now: Date = Date()) throws {
        guard !ids.isEmpty else { return }
        var state = try load()
        for index in state.notes.indices where ids.contains(state.notes[index].id) {
            state.notes[index].flushedAt = now.timeIntervalSince1970
        }
        try save(state)
    }

    private func load() throws -> OfflineAgentNotesState {
        guard fileManager.fileExists(atPath: storeURL.path) else {
            return OfflineAgentNotesState()
        }
        let data = try Data(contentsOf: storeURL)
        return try decoder.decode(OfflineAgentNotesState.self, from: data)
    }

    private func save(_ state: OfflineAgentNotesState) throws {
        let directory = storeURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let data = try encoder.encode(state)
        try data.write(to: storeURL, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeURL.path)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

extension CMUXCLI {
    func offlineNotesUsageHelp() -> String {
        """
        Usage: cmux notes <add|list|flush|clear|path> [options]

        Store notes while cmux or the network is unavailable, then submit them
        to an agent terminal later.

        Subcommands:
          add [--agent <name>] [--cwd <path>] [--workspace <id>] [--surface <id>] <text>
          list [--agent <name>] [--all]
          flush [--agent <name>] [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] [--all] [--dry-run]
          clear [--agent <name>] [--all]
          path

        Examples:
          cmux notes add --agent codex "After online, ask an agent to tighten the release notes"
          cmux notes list
          cmux notes flush --surface surface:2
        """
    }

    func offlineNotesCommandDoesNotNeedSocket(_ commandArgs: [String]) -> Bool {
        let subcommand = commandArgs.first?.lowercased() ?? "list"
        return subcommand != "flush"
    }

    func runOfflineNotesCommandWithoutSocket(commandArgs: [String], jsonOutput: Bool) throws {
        try runOfflineNotesCommand(
            commandArgs: commandArgs,
            client: nil,
            jsonOutput: jsonOutput,
            idFormat: .refs,
            windowOverride: nil
        )
    }

    func runOfflineNotesCommand(
        commandArgs: [String],
        client: SocketClient?,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let subcommand = commandArgs.first?.lowercased() ?? "list"
        let args = commandArgs.isEmpty ? [] : Array(commandArgs.dropFirst())
        let store = OfflineAgentNotesStore()

        switch subcommand {
        case "add":
            try runOfflineNotesAdd(args: args, store: store, jsonOutput: jsonOutput)
        case "list":
            try runOfflineNotesList(args: args, store: store, jsonOutput: jsonOutput)
        case "clear":
            try runOfflineNotesClear(args: args, store: store, jsonOutput: jsonOutput)
        case "path":
            guard args.isEmpty else {
                throw CLIError(message: "notes path does not accept arguments")
            }
            if jsonOutput {
                print(jsonString(["path": store.storeURL.path]))
            } else {
                print(store.storeURL.path)
            }
        case "flush":
            guard let client else {
                throw CLIError(message: "notes flush requires cmux to be running")
            }
            try runOfflineNotesFlush(
                args: args,
                store: store,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowOverride
            )
        default:
            throw CLIError(message: "notes: unknown subcommand '\(subcommand)'")
        }
    }

    private func runOfflineNotesAdd(
        args: [String],
        store: OfflineAgentNotesStore,
        jsonOutput: Bool
    ) throws {
        let (agent, rem0) = parseOption(args, name: "--agent")
        let (cwd, rem1) = parseOption(rem0, name: "--cwd")
        let (workspace, rem2) = parseOption(rem1, name: "--workspace")
        let (surface, rem3) = parseOption(rem2, name: "--surface")
        let trailing = rem3.dropFirst(rem3.first == "--" ? 1 : 0)
        let rawText = trailing.joined(separator: " ")
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw CLIError(message: "notes add requires text")
        }

        let environment = ProcessInfo.processInfo.environment
        let note = try store.add(
            text: text,
            agent: agent ?? environment["CMUX_AGENT_LAUNCH_KIND"],
            cwd: cwd ?? environment["PWD"],
            workspaceId: workspace ?? environment["CMUX_WORKSPACE_ID"],
            surfaceId: surface ?? environment["CMUX_SURFACE_ID"]
        )
        let pendingCount = try store.notes().count
        if jsonOutput {
            print(jsonString(["note": offlineNotePayload(note), "pending_count": pendingCount]))
        } else {
            print("OK note=\(shortOfflineNoteID(note.id)) pending=\(pendingCount)")
        }
    }

    private func runOfflineNotesList(
        args: [String],
        store: OfflineAgentNotesStore,
        jsonOutput: Bool
    ) throws {
        let (agent, rem0) = parseOption(args, name: "--agent")
        let includeFlushed = rem0.contains("--all")
        let trailing = rem0.filter { $0 != "--all" }
        if let unknown = trailing.first {
            throw CLIError(message: "notes list: unexpected argument '\(unknown)'")
        }

        let notes = try store.notes(includeFlushed: includeFlushed, agent: agent)
        if jsonOutput {
            print(jsonString(["notes": notes.map(offlineNotePayload)]))
            return
        }
        if notes.isEmpty {
            print(includeFlushed ? "No notes" : "No pending notes")
            return
        }
        for note in notes {
            let status = note.flushedAt == nil ? "pending" : "flushed"
            let agent = note.agent ?? "agent"
            print("\(shortOfflineNoteID(note.id))  \(status)  \(agent)  \(note.text)")
        }
    }

    private func runOfflineNotesClear(
        args: [String],
        store: OfflineAgentNotesStore,
        jsonOutput: Bool
    ) throws {
        let (agent, rem0) = parseOption(args, name: "--agent")
        let includeFlushed = rem0.contains("--all")
        let trailing = rem0.filter { $0 != "--all" }
        if let unknown = trailing.first {
            throw CLIError(message: "notes clear: unexpected argument '\(unknown)'")
        }
        let count = try store.clear(includeFlushed: includeFlushed, agent: agent)
        if jsonOutput {
            print(jsonString(["cleared": count]))
        } else {
            print("OK cleared=\(count)")
        }
    }

    private func runOfflineNotesFlush(
        args: [String],
        store: OfflineAgentNotesStore,
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let (agent, rem0) = parseOption(args, name: "--agent")
        let (workspace, rem1) = parseOption(rem0, name: "--workspace")
        let (surface, rem2) = parseOption(rem1, name: "--surface")
        let (windowOpt, rem3) = parseOption(rem2, name: "--window")
        let includeFlushed = rem3.contains("--all")
        let dryRun = rem3.contains("--dry-run")
        let trailing = rem3.filter { $0 != "--all" && $0 != "--dry-run" }
        if let unknown = trailing.first {
            throw CLIError(message: "notes flush: unexpected argument '\(unknown)'")
        }

        let notes = try store.notes(includeFlushed: includeFlushed, agent: agent)
        guard !notes.isEmpty else {
            if jsonOutput {
                print(jsonString(["flushed": 0, "notes": []]))
            } else {
                print(includeFlushed ? "No notes" : "No pending notes")
            }
            return
        }

        let text = offlineNotesPrompt(notes: notes)
        if !dryRun {
            var params: [String: Any] = ["text": text]
            let windowRaw = windowOpt ?? windowOverride
            let workspaceArg = workspace ?? (windowRaw == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            let surfaceArg = surface ?? (workspace == nil && windowRaw == nil ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] : nil)
            let winId = try normalizeWindowHandle(windowRaw, client: client)
            if let winId { params["window_id"] = winId }
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client, windowHandle: winId)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId, windowHandle: winId)
            if let sfId { params["surface_id"] = sfId }
            _ = try client.sendV2(method: "surface.send_text", params: params)
            try store.markFlushed(ids: Set(notes.map(\.id)))
        }

        if jsonOutput {
            print(jsonString([
                "flushed": dryRun ? 0 : notes.count,
                "dry_run": dryRun,
                "notes": notes.map(offlineNotePayload),
                "text": text,
            ]))
        } else if dryRun {
            print(text)
        } else {
            print("OK flushed=\(notes.count)")
        }
    }

    private func offlineNotesPrompt(notes: [OfflineAgentNoteRecord]) -> String {
        var lines = [
            "Offline cmux notes queued while you were away:",
            "",
        ]
        for note in notes {
            lines.append("- [\(shortOfflineNoteID(note.id))] \(note.text)")
        }
        lines.append("")
        lines.append("Please turn these into concrete next actions and start on the highest-impact one.")
        return lines.joined(separator: "\n") + "\r"
    }

    private func offlineNotePayload(_ note: OfflineAgentNoteRecord) -> [String: Any] {
        [
            "id": note.id,
            "text": note.text,
            "agent": note.agent ?? NSNull(),
            "cwd": note.cwd ?? NSNull(),
            "workspace_id": note.workspaceId ?? NSNull(),
            "surface_id": note.surfaceId ?? NSNull(),
            "created_at": note.createdAt,
            "flushed_at": note.flushedAt ?? NSNull(),
        ]
    }

    private func shortOfflineNoteID(_ id: String) -> String {
        String(id.prefix(8))
    }
}
