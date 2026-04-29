import AppKit
import Combine
import Foundation

/// Single source of truth for the named workspace commands surfaced by the
/// titlebar `+` picker, the command palette, and Cmd+N. Persisted to
/// UserDefaults as a single JSON blob so we can evolve the shape without
/// schema migrations across many keys. There is intentionally no JSON-file
/// fallback: workspace commands live in UserDefaults and are edited from the
/// Preferences UI.
@MainActor
final class WorkspaceCommandsStore: ObservableObject {
    static let shared = WorkspaceCommandsStore()

    static let didChange = Notification.Name("cmux.workspaceCommandsStore.didChange")

    private static let storageKey = "cmux.workspaceCommands.v1"

    /// Full command list surfaced to the UI: the built-in `Local` entry
    /// always comes first, followed by any commands the user added.
    var commands: [WorkspaceCommandConfig] {
        [Self.builtInLocal] + userCommands
    }
    /// User-added commands. Only these are persisted; the built-in `Local`
    /// command is synthesized at runtime so it can never be deleted.
    @Published private(set) var userCommands: [WorkspaceCommandConfig] = []
    /// Identifier of the command treated as the default for Cmd+N. `nil`
    /// resolves to the built-in `Local` command.
    @Published private(set) var defaultCommandID: WorkspaceCommandConfig.ID?

    private let defaults: UserDefaults
    private var suppressPersist = false

    /// Stable identifier for the built-in `Local` command so persisted
    /// `defaultCommandID` references survive across launches.
    static let builtInLocalID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    static var builtInLocal: WorkspaceCommandConfig {
        WorkspaceCommandConfig(
            id: builtInLocalID,
            name: String(
                localized: "settings.workspaces.builtIn.local.name",
                defaultValue: "Local"
            ),
            color: nil,
            restart: .always,
            remote: nil
        )
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    func command(id: WorkspaceCommandConfig.ID) -> WorkspaceCommandConfig? {
        commands.first(where: { $0.id == id })
    }

    /// Returns true when the given identifier refers to a built-in command
    /// the user can't rename or delete.
    func isBuiltIn(id: WorkspaceCommandConfig.ID) -> Bool {
        id == Self.builtInLocalID
    }

    func defaultCommand() -> WorkspaceCommandConfig? {
        if let id = defaultCommandID, let match = command(id: id) {
            return match
        }
        return Self.builtInLocal
    }

    /// Resets the store to its empty/built-in default state.
    func restoreDefaults() {
        defaultCommandID = nil
        applyUserCommands([])
    }

    func addCommand() -> WorkspaceCommandConfig {
        let new = WorkspaceCommandConfig(
            id: UUID(),
            name: defaultNewCommandName(),
            color: nil,
            restart: .always,
            remote: nil
        )
        var updated = userCommands
        updated.append(new)
        applyUserCommands(updated)
        return new
    }

    func update(_ command: WorkspaceCommandConfig) {
        guard !isBuiltIn(id: command.id) else { return }
        guard let index = userCommands.firstIndex(where: { $0.id == command.id }) else { return }
        var updated = userCommands
        updated[index] = command
        applyUserCommands(updated)
    }

    func remove(id: WorkspaceCommandConfig.ID) {
        guard !isBuiltIn(id: id) else { return }
        var updated = userCommands
        updated.removeAll(where: { $0.id == id })
        applyUserCommands(updated)
        if defaultCommandID == id {
            setDefault(id: nil)
        }
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        // Convert offsets from the surfaced list (built-in first) into the
        // persisted user-list. Drop any move that touches the built-in row;
        // it's pinned to the top.
        let builtInIndex = 0
        var translatedSource = IndexSet()
        for offset in source where offset != builtInIndex {
            translatedSource.insert(offset - 1)
        }
        guard !translatedSource.isEmpty else { return }
        let translatedDestination = max(destination - 1, 0)
        var updated = userCommands
        updated.move(fromOffsets: translatedSource, toOffset: translatedDestination)
        applyUserCommands(updated)
    }

    func setDefault(id: WorkspaceCommandConfig.ID?) {
        guard defaultCommandID != id else { return }
        defaultCommandID = id
        persist()
    }

    private func defaultNewCommandName() -> String {
        let base = String(localized: "settings.workspaces.newCommand.defaultName", defaultValue: "New Workspace")
        let existing = Set(commands.map(\.name))
        if !existing.contains(base) { return base }
        var n = 2
        while existing.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    private func applyUserCommands(_ next: [WorkspaceCommandConfig]) {
        userCommands = next
        if let defaultID = defaultCommandID,
           defaultID != Self.builtInLocalID,
           !next.contains(where: { $0.id == defaultID }) {
            defaultCommandID = nil
        }
        persist()
    }

    private func persist() {
        guard !suppressPersist else { return }
        let snapshot = StoredSnapshot(
            userCommands: userCommands,
            defaultCommandID: defaultCommandID
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: Self.storageKey)
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private func load() {
        guard let data = defaults.data(forKey: Self.storageKey) else { return }
        guard let snapshot = try? JSONDecoder().decode(StoredSnapshot.self, from: data) else { return }
        suppressPersist = true
        userCommands = snapshot.userCommands
        defaultCommandID = snapshot.defaultCommandID
        suppressPersist = false
    }

    private struct StoredSnapshot: Codable {
        var userCommands: [WorkspaceCommandConfig]
        var defaultCommandID: WorkspaceCommandConfig.ID?
    }
}

struct WorkspaceCommandConfig: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    /// Tab/title color as `#RRGGBB`. Optional.
    var color: String?
    var restart: Restart
    /// Program to run as the surface's child process for *non-remote* commands.
    /// Empty/nil falls back to Ghostty's default (the user's login shell or
    /// whatever `command =` is set to in `~/.config/ghostty/config`). Ignored
    /// when `remote != nil` — the SSH invocation always wins.
    var program: String?
    var remote: Remote?

    init(
        id: UUID,
        name: String,
        color: String? = nil,
        restart: Restart = .always,
        program: String? = nil,
        remote: Remote? = nil
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.restart = restart
        self.program = program
        self.remote = remote
    }

    enum Restart: String, Codable, Sendable, CaseIterable, Identifiable {
        case always
        case ignore
        case recreate
        case confirm

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .always:
                return String(localized: "settings.workspaces.restart.always", defaultValue: "Always create new")
            case .ignore:
                return String(localized: "settings.workspaces.restart.ignore", defaultValue: "Reuse existing")
            case .recreate:
                return String(localized: "settings.workspaces.restart.recreate", defaultValue: "Replace existing")
            case .confirm:
                return String(localized: "settings.workspaces.restart.confirm", defaultValue: "Ask before replacing")
            }
        }
    }

    struct Remote: Codable, Equatable, Sendable {
        var host: String
        var port: Int?
        var identityFile: String?
        var sshOptions: [String]
        var startupCommand: String?

        init(
            host: String = "",
            port: Int? = nil,
            identityFile: String? = nil,
            sshOptions: [String] = [],
            startupCommand: String? = nil
        ) {
            self.host = host
            self.port = port
            self.identityFile = identityFile
            self.sshOptions = sshOptions
            self.startupCommand = startupCommand
        }
    }
}

extension WorkspaceCommandConfig {
    /// Project the UserDefaults-backed configuration into the existing
    /// `CmuxCommandDefinition` shape so the existing executor pipeline can run
    /// it without changes.
    func asCmuxCommandDefinition() -> CmuxCommandDefinition {
        let trimmedProgram = program?.trimmingCharacters(in: .whitespacesAndNewlines)
        let workspace = CmuxWorkspaceDefinition(
            name: name,
            cwd: nil,
            color: color,
            layout: nil,
            remote: remote.map { remote in
                CmuxRemoteDefinition(
                    host: remote.host,
                    port: remote.port,
                    identityFile: remote.identityFile,
                    sshOptions: remote.sshOptions.isEmpty ? nil : remote.sshOptions,
                    startupCommand: remote.startupCommand
                )
            },
            program: (trimmedProgram?.isEmpty == false) ? trimmedProgram : nil
        )
        let restartBehavior: CmuxRestartBehavior = {
            switch restart {
            case .always: return .always
            case .ignore: return .ignore
            case .recreate: return .recreate
            case .confirm: return .confirm
            }
        }()
        return CmuxCommandDefinition(
            name: name,
            description: nil,
            keywords: nil,
            restart: restartBehavior,
            workspace: workspace,
            command: nil,
            confirm: nil
        )
    }
}

