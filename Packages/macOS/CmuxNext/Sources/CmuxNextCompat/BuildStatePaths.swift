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
    /// The launch's state root (``NextSupport/stateRootKey``), nil without one. Under a state root every build keeps
    /// its own settings, configuration and state (``ownsState``) in the root, as a DEV build does in its folder.
    public let stateRoot: URL?

    public init(build: BuildIdentity, userHome: URL, applicationSupport: URL, caches: URL, stateRoot: URL? = nil) {
        self.build = build
        self.userHome = userHome
        self.applicationSupport = applicationSupport
        self.caches = caches
        self.stateRoot = stateRoot
    }

    /// This process's paths, resolved once from the main bundle's identity.
    public static let current = BuildStatePaths(
        build: BuildIdentity(bundle: .main),
        userHome: FileManager.default.homeDirectoryForCurrentUser,
        applicationSupport: NextSupport.applicationSupportDirectory(),
        caches: NextSupport.cachesDirectory(),
        stateRoot: NextSupport.currentStateRoot
    )

    /// Whether this build keeps its own settings, configuration and state: every DEV build
    /// (`com.cmuxterm.app.debug[.<tag>]`, and any other `com.cmuxterm.app.*` bundle) and a tagged
    /// staging build (``BuildIdentity/needsBuildSpace``), the builds that have a cloud build space.
    public var isolatesSharedState: Bool { build.isolatesSharedState }

    /// Whether this launch keeps its own settings, configuration and state: a DEV build
    /// (``isolatesSharedState``), and any build under a state root.
    public var ownsState: Bool { isolatesSharedState || stateRoot != nil }

    /// `~/Library/Application Support/cmux-next/builds/<key>` for a DEV build or a launch under a state root (whose
    /// Application Support is the root's); nil for every other.
    public var ownRoot: URL? {
        ownsState ? build.appSupport(NextSupport(applicationSupport: applicationSupport).folder) : nil
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
    /// Under a state root it also ends in the root's ``NextSupport/runSegment(stateRoot:)``.
    public var cloudSecretsService: String {
        let service = isolatesSharedState ? "\(Self.sharedCloudSecretsService).\(build.key)" : Self.sharedCloudSecretsService
        return stateRoot.map { "\(service).\(NextSupport.runSegment(stateRoot: $0))" } ?? service
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
        ownsState ? build.appSupport(caches.appendingPathComponent("cmux-next", isDirectory: true)) : nil
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

    /// Browser tabs' thumbnails and favicons for the phones' tab overview (`PhoneTabPictures`), which hostd reads:
    /// `<Caches>/<bundle id>/phone-tab-pictures`, in a DEV build's own caches folder in a DEV build.
    public var phoneTabPicturesCache: URL {
        (ownCaches ?? caches.appendingPathComponent(build.bundleID ?? "cmux-next", isDirectory: true))
            .appendingPathComponent("phone-tab-pictures", isDirectory: true)
    }

    /// The `cmux vm` config a DEV build's CLI reads instead of the person's `~/.config/cmux/vm.json` (cmux-vm
    /// `CMUX_VM_DEFAULT_CONFIG`): `<config>/vm.json`; nil for every other build (cmux-vm's own default).
    public var vmConfigFile: URL? {
        ownRoot.map { _ in configDirectory.appendingPathComponent("vm.json", isDirectory: false) }
    }

    /// The tool lists `cmux mcp serve` keeps of a chat's other MCP servers (cmux-tui `upstream_listing`), instead of
    /// `~/.cache/cmux/mcp-upstreams`: in the DEV build's own caches; nil for every other build.
    public var mcpUpstreamsCache: URL? { ownCaches?.appendingPathComponent("mcp-upstreams", isDirectory: true) }

    /// The installed mux plugins (cmux-tui `plugin_manager`), instead of `~/.local/share/cmux/mux-plugins`; nil for
    /// every other build.
    public var muxPluginsDirectory: URL? { ownRoot?.appendingPathComponent("mux-plugins", isDirectory: true) }

    /// What a DEV build's daemon reads classic cmux's data from (`classic_import.*`): a folder that stands for
    /// classic's Application Support, its sessions in `cmux/` and the import's ledger in `cmux-next/<bundle id>/`.
    /// It starts empty, so a DEV build never imports the person's classic (production) workspaces; a test puts a
    /// classic session there to exercise the import. Nil for every other build (the person's classic data).
    public var classicImportDirectory: URL? { ownRoot?.appendingPathComponent("classic-import", isDirectory: true) }

    /// Whether this build imports classic cmux's preferences from the other channels' defaults
    /// (`ClassicPreferenceImport`): a DEV build never derives its settings from another build's.
    public var importsOtherBuildsPreferences: Bool { !ownsState }

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
    /// The `cmux vm` config (cmux-vm `config::default_config_path`).
    public static let vmConfigFileKey = "CMUX_VM_DEFAULT_CONFIG"
    /// The MCP tool lists (cmux-tui `cli/mcp/upstream_listing.rs`).
    public static let mcpUpstreamsCacheKey = "CMUX_NEXT_MCP_UPSTREAMS_DIR"
    /// The mux plugins (cmux-tui `plugin_manager::install_root`).
    public static let muxPluginsDirectoryKey = "CMUX_NEXT_MUX_PLUGINS_DIR"
    /// Classic cmux's data for the import (cmux-tui-core `classic_import_router::Places`).
    public static let classicImportDirectoryKey = "CMUX_NEXT_CLASSIC_IMPORT_DIR"
    /// The build's settings defaults (``SettingsBuildDefaults``, a JSON object of dotted keys) for the Rust settings
    /// owner (cmux-config `BUILD_DEFAULTS_ENV`): set by the launch for every build that has any, not only a DEV build.
    public static let settingsBuildDefaultsKey = "CMUX_NEXT_SETTINGS_BUILD_DEFAULTS"

    /// Every variable ``environment`` may set: the daemon's and acpmux's allow-listed environments pass these on.
    public static let environmentKeys = [settingsFileKey, cloudSecretsFileKey, cloudSecretsServiceKey, keysAuditFileKey,
                                         hostBudgetFileKey, automationsDirectoryKey, customizeDirectoryKey, agentSkillsDirectoryKey,
                                         vmConfigFileKey, mcpUpstreamsCacheKey, muxPluginsDirectoryKey, classicImportDirectoryKey]

    /// What an allow-listed child (the daemon, acpmux) gets from the app's environment: ``environmentKeys``, the
    /// build's settings defaults and the launch's state root (the daemon's Cloud selection and sign-in are the run's).
    public static let childEnvironmentKeys = environmentKeys + [settingsBuildDefaultsKey, NextSupport.stateRootKey]

    /// What this build's children read its files from: every ``environmentKeys`` entry for a DEV
    /// build or a launch under a state root, nothing for every other (they keep reading the shared defaults).
    public var environment: [String: String] {
        guard ownsState else { return [:] }
        var environment = [Self.settingsFileKey: settingsFile.path, Self.cloudSecretsFileKey: cloudSecretsIndex.path,
                           Self.cloudSecretsServiceKey: cloudSecretsService, Self.keysAuditFileKey: keysAuditFile.path,
                           Self.hostBudgetFileKey: hostBudgetFile.path, Self.automationsDirectoryKey: automationsDirectory.path,
                           Self.customizeDirectoryKey: customizeDirectory.path, Self.agentSkillsDirectoryKey: agentSkillsDirectory.path]
        environment[Self.vmConfigFileKey] = vmConfigFile?.path
        environment[Self.mcpUpstreamsCacheKey] = mcpUpstreamsCache?.path
        environment[Self.muxPluginsDirectoryKey] = muxPluginsDirectory?.path
        environment[Self.classicImportDirectoryKey] = classicImportDirectory?.path
        return environment
    }

    /// What `CmuxNextApp.prepareLaunchEnvironment` sets in the app's environment: each ``environment`` entry the
    /// process does not have yet, so an explicit test override (`--config-file`, a harness's
    /// `CMUX_NEXT_CONFIG_FILE`) keeps its file. Another build's values never get here: `LaunchIdentity`
    /// strips them first.
    public func launchEnvironment(over process: [String: String]) -> [String: String] {
        environment.filter { key, _ in process[key].map(\.isEmpty) ?? true }
    }

    /// The values of ``childEnvironmentKeys`` set in `environment` (a process environment), to pass to a child
    /// whose environment is an allow list.
    public static func childEnvironment(from environment: [String: String]) -> [String: String] {
        childEnvironmentKeys.reduce(into: [:]) { out, key in
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
    ///
    /// A DEV build (``isolatesSharedState``) names it by its ``key``, so two copies of one bundle id with their own
    /// shipped tags (`com.cmuxterm.app.debug` with `CMUX_TAG` a and b) never share it. A tagged DEV build
    /// (`com.cmuxterm.app.debug.<tag>`) and the untagged one have their bundle id as key, so their folders stay
    /// where they are; NIGHTLY, cmux NEXT, RC and release keep the bundle id. Another bundle id than this build's
    /// is that bundle's own folder.
    public func stateFolderName(for bundleID: String?) -> String? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        guard isolatesSharedState, let own = self.bundleID, Array(own.utf8) == Array(bundleID.utf8) else { return bundleID }
        return key
    }
}
