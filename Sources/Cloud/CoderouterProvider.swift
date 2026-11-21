import Foundation

/// An account type CodeRouter routes, named exactly as `coderouter accounts
/// --json` reports it in each account's `provider` (the server's provider names).
struct CoderouterProvider: Hashable {
    let id: String

    static let codex = CoderouterProvider(id: "codex")
    static let claude = CoderouterProvider(id: "claude")
    static let opencodeGo = CoderouterProvider(id: "opencode-go")
    static let openaiAPIKey = CoderouterProvider(id: "openai-apikey")
    static let openrouterAPIKey = CoderouterProvider(id: "openrouter-apikey")

    /// The types `cr add <type>` adds, in sidebar order. Each keeps its group
    /// and New Account row even before the team has an account of that type.
    /// API-key types have no `cr add` flow yet; their accounts still list.
    static let addable: [CoderouterProvider] = [.codex, .claude, .opencodeGo]

    var canAdd: Bool { Self.addable.contains(self) }

    var title: String {
        switch id {
        case "codex": return "Codex"
        case "claude": return "Claude"
        case "opencode-go": return "OpenCode"
        case "openai-apikey": return "OpenAI API Key"
        case "openrouter-apikey": return "OpenRouter API Key"
        default: return id.capitalized
        }
    }

    var newAccountTitle: String {
        String(format: String(localized: "coderouter.newAccount", defaultValue: "New %@ Account"), title)
    }

    /// The unscoped command shown in the guide and used by ordinary terminal
    /// users. Sidebar setup runs `CoderouterAppCLISession.addAccountCommand`.
    var addCommand: String {
        switch id {
        case "opencode-go": return "cmux cr add opencode"
        default: return "cmux cr add \(id)"
        }
    }
}

/// The local terminal launch used by a New Account row. Account setup is
/// interactive, so it always owns a fresh focused terminal instead of writing
/// into whichever terminal happens to be selected (which may be an agent TUI).
struct CoderouterAccountTerminalLaunch: Equatable {
    let command: [String]
    let name: String
    let focus: Bool

    init(provider: CoderouterProvider) {
        command = ["sh", "-lc", provider.addCommand]
        name = "CodeRouter"
        focus = true
    }
}

/// Persists the local workspace used when CodeRouter setup is requested while
/// the selected workspace belongs to Cloud or another remote machine.
///
/// The UUID is deliberately the only persisted value. The workspace's live
/// ownership and existence are checked by ``CoderouterSetupWorkspaceCoordinator``
/// before every reuse, so a deleted or converted workspace cannot receive a
/// local account command by accident.
struct CoderouterSetupWorkspacePersistence {
    static let userDefaultsKey = "coderouter.setupWorkspaceID"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func save(workspaceID: UUID) {
        defaults.set(workspaceID.uuidString, forKey: Self.userDefaultsKey)
    }

    func clear() {
        defaults.removeObject(forKey: Self.userDefaultsKey)
    }

    /// Resolves the stored ID and removes malformed or stale state in one read.
    @discardableResult
    func validatedWorkspaceID(isValid: (UUID) -> Bool) -> UUID? {
        guard let rawValue = defaults.string(forKey: Self.userDefaultsKey),
              let workspaceID = UUID(uuidString: rawValue),
              isValid(workspaceID) else {
            clear()
            return nil
        }
        return workspaceID
    }
}

enum CoderouterSetupWorkspaceRoute: Equatable {
    case selectedWorkspace
    case persistedSetupWorkspace
    case createSetupWorkspace

    static func resolve(
        selectedWorkspaceIsLocal: Bool,
        persistedSetupWorkspaceIsValid: Bool
    ) -> Self {
        if selectedWorkspaceIsLocal { return .selectedWorkspace }
        if persistedSetupWorkspaceIsValid { return .persistedSetupWorkspace }
        return .createSetupWorkspace
    }
}

/// Chooses the local destination for a CodeRouter account setup command.
///
/// A selected local workspace is the least surprising destination. Cloud and
/// remote workspaces cannot host the local CLI process, so those requests use
/// one persisted local workspace named `CodeRouter Setup`.
@MainActor
struct CoderouterSetupWorkspaceCoordinator {
    static let workspaceTitle = String(
        localized: "coderouter.setup.workspaceTitle",
        defaultValue: "CodeRouter Setup"
    )

    private let managerSource: @MainActor () -> TabManager?
    private let provider: CoderouterProvider
    private let initialTerminalCommand: String?
    private let persistence: CoderouterSetupWorkspacePersistence

    init(
        managerSource: @escaping @MainActor () -> TabManager?,
        provider: CoderouterProvider,
        initialTerminalCommand: String? = nil,
        persistence: CoderouterSetupWorkspacePersistence = CoderouterSetupWorkspacePersistence()
    ) {
        self.managerSource = managerSource
        self.provider = provider
        self.initialTerminalCommand = initialTerminalCommand
        self.persistence = persistence
    }

    enum Destination {
        case existing(workspace: Workspace, manager: TabManager)
        case created(workspace: Workspace, manager: TabManager)
    }

    func resolveDestination() -> Destination? {
        let manager = managerSource().flatMap { manager in
            manager.isFinalizedForWindowClose ? nil : manager
        }
        let selectedWorkspace = manager?.selectedWorkspace
        let selectedWorkspaceIsLocal = manager.map { manager in
            !manager.isFinalizedForWindowClose
                && selectedWorkspace.map { Self.isLocal($0) } == true
        } == true
        let setup = Self.persistedLocalWorkspace(using: persistence)

        switch CoderouterSetupWorkspaceRoute.resolve(
            selectedWorkspaceIsLocal: selectedWorkspaceIsLocal,
            persistedSetupWorkspaceIsValid: setup != nil
        ) {
        case .selectedWorkspace:
            guard let manager, let selectedWorkspace else { return nil }
            return .existing(workspace: selectedWorkspace, manager: manager)
        case .persistedSetupWorkspace:
            guard let setup else { return nil }
            setup.manager.selectWorkspace(setup.workspace)
            return .existing(workspace: setup.workspace, manager: setup.manager)
        case .createSetupWorkspace:
            break
        }

        guard let manager,
              !manager.isFinalizedForWindowClose,
              let workspace = manager.addWorkspaceIfActive(
                  title: Self.workspaceTitle,
                  titleSource: .user,
                  initialTerminalCommand: initialTerminalCommand ?? provider.addCommand,
                  inheritWorkingDirectory: false,
                  select: true,
                  autoWelcomeIfNeeded: false,
                  autoRefreshMetadata: false
              ) else {
            return nil
        }
        persistence.save(workspaceID: workspace.id)
        return .created(workspace: workspace, manager: manager)
    }

    /// Admits and creates setup directly in its local destination in one main
    /// actor turn. Staging a running shell elsewhere before projecting it can
    /// fail after launch, making the caller delete a configuration still in use.
    func launchAccountTerminal(in workspaceID: UUID) throws {
        guard let manager = AppDelegate.shared?.tabManagerFor(tabId: workspaceID),
              !manager.isFinalizedForWindowClose,
              let workspace = manager.tabs.first(where: { $0.id == workspaceID }),
              Self.isLocal(workspace) else {
            throw SurfacePaneFactory.FactoryError.workspaceNotFound(workspaceID)
        }
        // The split selects its workspace before the terminal's own room
        // check, so refuse a full destination here: a refused setup must
        // leave the person's selected workspace where it was.
        if let anchor = workspace.focusedPanelId,
           workspace.terminalSplitSpaceVerdict(splittingPanel: anchor, orientation: .horizontal) == .noSpace {
            throw SurfacePaneFactory.FactoryError.noSpace
        }
        let command = ["sh", "-lc", initialTerminalCommand ?? provider.addCommand]
        let created = try SurfacePaneFactory.makeTerminalPane(
            initialCommand: command.map(LocalSurfaceProvider.shellQuote).joined(separator: " "),
            workingDirectory: nil,
            at: .workspace(id: workspaceID, placement: .split),
            focus: true
        )
        // Match the local provider's terminal name without pinning a custom
        // tab title that would prevent the shell from updating its own title.
        let catalog = SurfaceCatalog.shared
        let resourceID = LocalSurfaceProvider.resourceID(forTerminalPanel: created.panelID)
        if var resource = catalog.resources[resourceID] {
            resource.title = "CodeRouter"
            catalog.upsert(resource)
        }
    }

    private static func persistedLocalWorkspace(
        using persistence: CoderouterSetupWorkspacePersistence
    ) -> (workspace: Workspace, manager: TabManager)? {
        guard let workspaceID = persistence.validatedWorkspaceID(isValid: { workspaceID in
            guard let manager = AppDelegate.shared?.tabManagerFor(tabId: workspaceID),
                  !manager.isFinalizedForWindowClose,
                  let workspace = manager.tabs.first(where: { $0.id == workspaceID }) else {
                return false
            }
            return Self.isLocal(workspace)
        }),
        let manager = AppDelegate.shared?.tabManagerFor(tabId: workspaceID),
        !manager.isFinalizedForWindowClose,
        let workspace = manager.tabs.first(where: { $0.id == workspaceID }),
        Self.isLocal(workspace) else {
            return nil
        }
        return (workspace, manager)
    }

    /// Ownership comes from the workspace's binding state rather than its
    /// visible title. An intentionally mixed local/cloud workspace remains a
    /// valid local destination for a new local pane; fully remote, bound, and
    /// cloud-only projection workspaces are excluded.
    private static func isLocal(_ workspace: Workspace) -> Bool {
        workspace.canHostLocalTerminal
    }
}

/// What the Cloud tree's CodeRouter section shows: the selected team's
/// accounts, whether a refresh is running, and why the last read failed.
struct CloudTreeCoderouterSection: Equatable {
    var accounts: [CloudTreeNode.CoderouterAccount] = []
    var isRefreshing = false
    var failure: CoderouterCLIFailure?
}
