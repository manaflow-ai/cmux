public import Foundation

/// Where a build keeps the settings, configuration and state files that every build once shared:
/// `~/.config/cmux` (the settings file and what lives beside it), `cmux-next/recovery`,
/// `cmux/agent-home` and `cmux/Chat Uploads` in Application Support, and the `cmux` caches.
///
/// The user, 2026-11-16: "for dev builds we must make sure that all such values and configurations
/// have a dev build isolation that prevents each dev build from deriving state from each other even
/// from prod." A DEV build (``isolatesSharedState``) keeps each of them in its own folder,
/// `~/Library/Application Support/cmux-next/builds/<key>` (``BuildIdentity/appSupport(_:)``), and
/// its caches in `~/Library/Caches/cmux-next/builds/<key>`. It starts them empty: nothing is copied
/// or read from nightly's, stable's or another tag's files, so a fresh DEV build has the schema's
/// defaults and its build defaults (`SettingsBuildDefaults`). NIGHTLY, cmux NEXT, RC, release, an
/// untagged staging build and a process outside any bundle keep the shared paths exactly as before.
///
/// Rust children (the daemon, acpmux, the `cmux` CLI in the build's terminals) read the same files
/// through the variables of ``environment``, which `CmuxNextApp.prepareLaunchEnvironment` sets in the
/// app's own environment before anything starts, so every child inherits them.
///
/// Not here, on purpose: the dev sign-in inputs `~/.config/cmux/dev-account` and
/// `~/.secrets/cmuxterm-dev.env` (inputs of this Mac, read by every dev build), managed (MDM) policy,
/// the user's Ghostty config, and the user-mode server's `server.json` (one server per Mac, which a
/// DEV build never registers). Everything a build stores under its bundle id (UserDefaults, Keychain
/// services `<bundle id>.*`, Application Support and Caches `<bundle id>/`) is already its own.
public nonisolated struct BuildStatePaths: Sendable, Equatable {
    public let build: BuildIdentity
    /// The account's home (never `$HOME`).
    public let userHome: URL
    /// `~/Library/Application Support`.
    public let applicationSupport: URL
    /// `~/Library/Caches`.
    public let caches: URL

    public init(build: BuildIdentity, userHome: URL, applicationSupport: URL, caches: URL) {
        self.build = build
        self.userHome = userHome
        self.applicationSupport = applicationSupport
        self.caches = caches
    }

    /// This process's paths, resolved once from the main bundle's identity.
    public static let current = BuildStatePaths(
        build: BuildIdentity(bundle: .main),
        userHome: FileManager.default.homeDirectoryForCurrentUser,
        applicationSupport: NextSupport.applicationSupportDirectory(),
        caches: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches", isDirectory: true)
    )

    /// Whether this build keeps its own settings, configuration and state: every DEV build
    /// (`com.cmuxterm.app.debug[.<tag>]`, and any other `com.cmuxterm.app.*` bundle) and a tagged
    /// staging build (``BuildIdentity/needsBuildSpace``), the builds that have a cloud build space.
    public var isolatesSharedState: Bool { build.isolatesSharedState }

    /// `~/Library/Application Support/cmux-next/builds/<key>` for a DEV build; nil for every other.
    public var ownRoot: URL? {
        isolatesSharedState ? build.appSupport(NextSupport(applicationSupport: applicationSupport).folder) : nil
    }

    /// The folder of the settings file and what lives beside it (`themes/`, `keybindings.json`,
    /// `agent-pane/`, `diff/languages/`): `~/.config/cmux`, or `<own root>/config` for a DEV build.
    public var configDirectory: URL {
        ownRoot?.appendingPathComponent("config", isDirectory: true)
            ?? userHome.appendingPathComponent(".config/cmux", isDirectory: true)
    }

    /// `cmux-next.json` (`CmuxConfigFile`).
    public var settingsFile: URL { configDirectory.appendingPathComponent("cmux-next.json", isDirectory: false) }
    /// The Cloud machine secrets index, names only (`cmux cloud secret`).
    public var cloudSecretsIndex: URL { configDirectory.appendingPathComponent("cloud-secrets.json", isDirectory: false) }
    /// The host CPU/RAM budget overrides (`HostBudgetFile`, cmux-host-budget).
    public var hostBudgetFile: URL { configDirectory.appendingPathComponent("host-budget.json", isDirectory: false) }
    /// The provider keys audit (`cmux keys`), names and ids only.
    public var keysAuditFile: URL { configDirectory.appendingPathComponent("keys.json", isDirectory: false) }
    /// The automations store (cmux-automations).
    public var automationsDirectory: URL { configDirectory.appendingPathComponent("automations", isDirectory: true) }
    /// The person's own views app (`CustomizeFolder`, cmux-customize). Shared builds keep their rule
    /// (`CMUX_CUSTOMIZE_DIR`, `XDG_CONFIG_HOME`, `~/.config/cmux/customize`); this is that rule's default.
    public var customizeDirectory: URL { configDirectory.appendingPathComponent("customize", isDirectory: true) }
    /// The person's own agent skills (acpmux `user_skills_dir`).
    public var agentSkillsDirectory: URL { configDirectory.appendingPathComponent("skills", isDirectory: true) }
    /// The Keychain service of the Cloud secrets `cmux cloud secret set` stores (`CloudMachineSecrets`): a DEV
    /// build's values never overwrite or read nightly's.
    public var cloudSecretsService: String {
        isolatesSharedState ? "\(Self.sharedCloudSecretsService).\(build.key)" : Self.sharedCloudSecretsService
    }
    /// The Cloud secrets service every shared build uses.
    public static let sharedCloudSecretsService = "cmux-cloud-secret"
    /// The GitHub feed's worktrees.
    public var githubWorktrees: URL {
        ownRoot?.appendingPathComponent("github-worktrees", isDirectory: true) ?? configDirectory.appendingPathComponent("github-worktrees", isDirectory: true)
    }

    /// Unsent drafts kept at quit (`RecoveryDraftStore`).
    public var recoveryDrafts: URL {
        ownRoot?.appendingPathComponent("recovery", isDirectory: true)
            ?? NextSupport(applicationSupport: applicationSupport).folder.appendingPathComponent("recovery", isDirectory: true)
    }

    /// The folder of every workspace's agent home (`AgentHome`).
    public var agentHome: URL {
        ownRoot?.appendingPathComponent("agent-home", isDirectory: true)
            ?? applicationSupport.appendingPathComponent("cmux", isDirectory: true).appendingPathComponent("agent-home", isDirectory: true)
    }

    /// Files attached to chats (`ChatUploadFolders`).
    public var chatUploads: URL {
        ownRoot?.appendingPathComponent("Chat Uploads", isDirectory: true)
            ?? applicationSupport.appendingPathComponent("cmux", isDirectory: true).appendingPathComponent("Chat Uploads", isDirectory: true)
    }

    /// `~/Library/Caches/cmux-next/builds/<key>` for a DEV build; nil for every other.
    var ownCaches: URL? {
        isolatesSharedState ? build.appSupport(caches.appendingPathComponent("cmux-next", isDirectory: true)) : nil
    }

    /// The root of Home's caches (`AppEnvironment.homeCachesDirectory`: `cmux-home/<owner>`, `cmux-home-blobs`):
    /// `~/Library/Caches`, a DEV build's own caches folder in a DEV build.
    public var homeCachesRoot: URL { ownCaches ?? caches }

    /// Projects' owner avatars (`AgentPaneOwnerAvatars`).
    public var projectAvatarsCache: URL {
        ownCaches?.appendingPathComponent("project-avatars", isDirectory: true)
            ?? caches.appendingPathComponent("cmux", isDirectory: true).appendingPathComponent("project-avatars", isDirectory: true)
    }

    /// The shell mode's completion dump folder (`AgentPaneShellCompletion`).
    public var shellCompletionCache: URL { ownCaches ?? caches.appendingPathComponent("cmux-next", isDirectory: true) }

    /// Whether this build imports classic cmux's preferences from the other channels' defaults
    /// (`ClassicPreferenceImport`): a DEV build never derives its settings from another build's.
    public var importsOtherBuildsPreferences: Bool { !isolatesSharedState }

    // MARK: - Children

    /// The settings file (cmux-config `CONFIG_OVERRIDE`, acpmux, cmux-tui-util).
    public static let settingsFileKey = "CMUX_NEXT_CONFIG_FILE"
    /// The Cloud secrets index (cmux-tui `cli/cloud_secret.rs`).
    public static let cloudSecretsFileKey = "CMUX_NEXT_CLOUD_SECRETS_FILE"
    /// The keys audit (cmux-tui `cli/key_broker.rs`).
    public static let keysAuditFileKey = "CMUX_NEXT_KEYS_AUDIT_FILE"
    /// The host budget (cmux-host-budget `OVERRIDE_ENV`).
    public static let hostBudgetFileKey = "ACPMUX_HOST_BUDGET"
    /// The automations store (cmux-automations `Store::default_root`).
    public static let automationsDirectoryKey = "CMUX_AUTOMATIONS_DIR"
    /// The customize folder (cmux-customize `Roots`, cmux-tui-core `apps::catalog::customize_dir`).
    public static let customizeDirectoryKey = "CMUX_CUSTOMIZE_DIR"
    /// The agent skills folder (acpmux `USER_SKILLS_DIR_ENV`).
    public static let agentSkillsDirectoryKey = "CMUX_AGENT_SKILLS_DIR"
    /// The Cloud secrets Keychain service (cmux-tui `cli/cloud_secret.rs`).
    public static let cloudSecretsServiceKey = "CMUX_NEXT_CLOUD_SECRETS_SERVICE"

    /// Every variable ``environment`` may set: the daemon's and acpmux's allow-listed environments pass these on.
    public static let environmentKeys = [settingsFileKey, cloudSecretsFileKey, cloudSecretsServiceKey, keysAuditFileKey,
                                         hostBudgetFileKey, automationsDirectoryKey, customizeDirectoryKey, agentSkillsDirectoryKey]

    /// What this build's children read its files from: every ``environmentKeys`` entry for a DEV
    /// build, nothing for every other (they keep reading the shared defaults).
    public var environment: [String: String] {
        guard isolatesSharedState else { return [:] }
        return [Self.settingsFileKey: settingsFile.path, Self.cloudSecretsFileKey: cloudSecretsIndex.path,
                Self.cloudSecretsServiceKey: cloudSecretsService, Self.keysAuditFileKey: keysAuditFile.path,
                Self.hostBudgetFileKey: hostBudgetFile.path, Self.automationsDirectoryKey: automationsDirectory.path,
                Self.customizeDirectoryKey: customizeDirectory.path, Self.agentSkillsDirectoryKey: agentSkillsDirectory.path]
    }

    /// What `CmuxNextApp.prepareLaunchEnvironment` sets in the app's environment: each ``environment`` entry the
    /// process does not have yet, so an explicit test override (`--config-file`, a harness's
    /// `CMUX_NEXT_CONFIG_FILE`) keeps its file. Another build's values never get here: `LaunchIdentity`
    /// strips them first.
    public func launchEnvironment(over process: [String: String]) -> [String: String] {
        environment.filter { key, _ in process[key].map(\.isEmpty) ?? true }
    }

    /// The values of ``environmentKeys`` set in `environment` (a process environment), to pass to a child
    /// whose environment is an allow list.
    public static func childEnvironment(from environment: [String: String]) -> [String: String] {
        environmentKeys.reduce(into: [:]) { out, key in
            if let value = environment[key], !value.isEmpty { out[key] = value }
        }
    }

    /// The Cloud secrets index a process with `environment` uses: ``cloudSecretsFileKey``, else
    /// `<home>/.config/cmux/cloud-secrets.json` (Rust's `cloud_secret::index_path`).
    public static func cloudSecretsIndex(environment: [String: String], home: URL) -> URL {
        if let path = environment[cloudSecretsFileKey], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return home.appendingPathComponent(".config/cmux/cloud-secrets.json", isDirectory: false)
    }

    /// The Cloud secrets Keychain service a process with `environment` uses: ``cloudSecretsServiceKey``, else
    /// the shared one (Rust's `cloud_secret::service`).
    public static func cloudSecretsService(environment: [String: String]) -> String {
        environment[cloudSecretsServiceKey].flatMap { $0.isEmpty ? nil : $0 } ?? sharedCloudSecretsService
    }

    /// Every path above by name, for the tests that hold DEV paths apart from NIGHTLY's.
    public var all: [(name: String, url: URL)] {
        [("configDirectory", configDirectory), ("settingsFile", settingsFile), ("cloudSecretsIndex", cloudSecretsIndex),
         ("hostBudgetFile", hostBudgetFile), ("keysAuditFile", keysAuditFile), ("automationsDirectory", automationsDirectory),
         ("customizeDirectory", customizeDirectory), ("agentSkillsDirectory", agentSkillsDirectory), ("githubWorktrees", githubWorktrees), ("recoveryDrafts", recoveryDrafts),
         ("agentHome", agentHome), ("chatUploads", chatUploads), ("projectAvatarsCache", projectAvatarsCache),
         ("shellCompletionCache", shellCompletionCache), ("homeCachesRoot", homeCachesRoot)]
    }
}

extension BuildIdentity {
    /// Whether this build keeps settings, configuration and state of its own instead of the shared ones
    /// (``BuildStatePaths``): every DEV build (any `com.cmuxterm.app.*` bundle of no shipped kind) and a
    /// tagged staging build (``needsBuildSpace``).
    public var isolatesSharedState: Bool { kind == .dev || needsBuildSpace }
}

extension BuildIdentity {
    /// The folder name of the state a build keeps under its bundle id (`<Application Support>/<name>`,
    /// `<Caches>/<name>`): the Chief home, the mobile host's state and the browser profiles. `bundleID` names
    /// the build the caller resolves for; nil when it is blank.
    public func stateFolderName(for bundleID: String?) -> String? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        return bundleID
    }
}
