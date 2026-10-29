import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextTabs
import CmuxNextTerminal
import Observation

/// Room, workspace and terminal themes (plans/cmux-next/data-model.md 6).
///
/// Each window has a room scope (its adopted `ThemeScope`), each mounted
/// workspace content a workspace scope under it, each live terminal a
/// terminal scope under its pane's workspace. This object sets their themes
/// from personal state (room `theme`, personal workspace `theme`) and the
/// app-local terminal themes, and keeps every terminal surface on the theme
/// in effect for it (terminal, workspace, room, Ghostty config). It runs on
/// change events only: one observation of the theme fields, the resolver's
/// config and light/dark changes, and mount calls from the controllers.
@MainActor
final class ThemeCoordinator {
    let resolver = ThemeResolver()
    let terminalThemes: TerminalThemeStore
    /// Every Ghostty theme, for pickers and validation.
    let catalog = ThemeCatalog()
    unowned let services: AppServices
    /// A theme shown live while a picker highlights it, not saved.
    private(set) var preview: ThemePreview?
    /// Room and workspace themes just set here and not yet echoed by the
    /// daemon (optimistic, so a picker's revert never flashes the old
    /// theme). An inner nil is "Use Ghostty Config".
    var pending: [ThemePreview.Target: String?] = [:]
    /// Which room, workspace or terminal a theme action acts on, resolved
    /// like its handler (`ThemeHandlers`), for picker previews.
    var previewTarget: (@MainActor (ActionID, ActionTargetRef?) -> ThemePreview.Target?)?
    private var observation: Task<Void, Never>?
    /// Each workspace's own background (`ThemeCoordinator+Backgrounds`).
    let workspaceBackgrounds: WorkspaceBackgroundStore
    /// Each workspace's own glass tint over art, as text ("0.6").
    let workspaceOpacities: WorkspaceBackgroundStore
    /// Every window, workspace, pane and tab value the other stores do not keep
    /// (`ThemeCoordinator+AppearanceScopes`), keyed `<level>:<id>|<property>`.
    let appearanceScopes: WorkspaceBackgroundStore
    /// A workspace background the picker shows without saving it; the inner nil follows the app's.
    var backgroundPreview: (workspace: String, value: String?)?
    /// A workspace tint the picker's slider shows without saving it; nil follows the work's.
    var opacityPreview: (workspace: String, value: Double?)?
    /// Shows a Shuffle Daily workspace's next work when the day turns.
    var dayObservers: [any NSObjectProtocol] = []
    /// The scopes whose theme this coordinator set.
    private let themed = NSHashTable<ThemeScope>.weakObjects()
    /// The applies each live terminal took: an apply reaches the shown ones, the parked catch up.
    private let applies = ThemeApplyLedger()

    init(services: AppServices, terminalThemes: TerminalThemeStore, workspaceBackgrounds: WorkspaceBackgroundStore? = nil,
         workspaceOpacities: WorkspaceBackgroundStore? = nil,
         appearanceScopes: WorkspaceBackgroundStore? = nil) {
        self.services = services
        self.terminalThemes = terminalThemes
        self.workspaceBackgrounds = workspaceBackgrounds
            ?? .forApplication(bundleIdentifier: services.environment.launch.bundleID)
        self.workspaceOpacities = workspaceOpacities
            ?? .forApplication(bundleIdentifier: services.environment.launch.bundleID, file: "workspace-background-opacity.json")
        self.appearanceScopes = appearanceScopes
            ?? .forApplication(bundleIdentifier: services.environment.launch.bundleID, file: "appearance-scopes.json")
        resolver.onChange = { [weak self] in
            self?.apply(forceSurfaces: true)
            self?.applyChromeTheme()
        }
    }

    // MARK: App theme (appearance.appTheme)

    /// `appearance.appTheme` as last read; nil follows the terminal theme.
    private var chromeTheme: String?
    private var chromeObservation: Task<Void, Never>?
    private var accentObservation: Task<Void, Never>?
    private var artAccentObservation: Task<Void, Never>?
    private var machineColorsObservation: Task<Void, Never>?

    /// Follows `appearance.appTheme`: the app theme pages get (`--cmux-app-*`, `WebTheme`),
    /// resolved like the other theme levels (the variant for the system appearance, the user's
    /// explicit config colors over it). `followTerminal` leaves each scope on its own theme.
    func followChromeTheme(_ settings: SettingsController) {
        let store = services.themeStore
        // `applied`: a live preview (a theme picker's highlighted row) shows too.
        chromeTheme = settings.applied.chromeTheme
        store.setAccent(settings.applied.accent)
        store.setAccentFollowsArt(AccentSetting.followsArt(settings.applied.root))
        applyChromeTheme()
        artAccentObservation = Task { [weak self] in
            for await follows in ObservationStream({ AccentSetting.followsArt(settings.applied.root) }) {
                guard store.setAccentFollowsArt(follows) else { continue }
                self?.applyChromeTheme()
            }
        }
        // `appearance.accent` re-derives the terminal-theme tokens (the store) and the app theme.
        accentObservation = Task { [weak self] in
            for await accent in ObservationStream({ settings.applied.accent }) {
                guard let self, store.setAccent(accent) else { continue }
                self.applyChromeTheme()
            }
        }
        chromeObservation = Task { [weak self] in
            for await theme in ObservationStream({ settings.applied.chromeTheme }) {
                guard let self, theme != self.chromeTheme else { continue }
                self.chromeTheme = theme
                self.applyChromeTheme()
            }
        }
        // `appearance.machineColors`: every machine mark reads the store's picks (MachineColor).
        store.setMachineColors(settings.applied.machineColors)
        machineColorsObservation = Task {
            for await colors in ObservationStream({ settings.applied.machineColors }) { store.setMachineColors(colors) }
        }
    }

    private func applyChromeTheme() {
        let store = services.themeStore
        let resolved = chromeTheme.flatMap(ThemeSpec.init).flatMap(resolver.resolve)
        store.setAppTheme(resolved.map {
            var input = $0.input
            input.accent = store.accent
            // Art Color: pages take the app's art hue (a workspace's own art tints its chrome only).
            if store.accentFollowsArt, let hue = ThemeScope.app.backdropArt?.accentHue { input.accentColor = hue }
            return AppTheme.derive(from: input)
        })
    }

    func start() {
        let registry = services.registry
        registry.choicePreview = { [weak self] action, _, value, target in
            self?.pickerPreview(action, value: value, target: target)
        }
        // Other owners (Team Picker) keep the current values they installed.
        let otherState = registry.choiceState
        registry.choiceState = { [weak self] action, target in self?.currentChoice(action, target: target) ?? otherState?(action, target) }
        let catalog = catalog
        // A theme's own accent: its `<theme>/accent` edit, else its file's `# cmux-accent`.
        ThemeBridge.accent = { name in ThemeBridge.edited(name) ?? catalog.colors[name]?.accent }
        // File accents arrive with the catalog's colors, which no config reload reports; only a
        // change in them re-derives (and re-applies the surfaces).
        var fileAccents: [String: ThemeRGB] = [:]
        catalog.onRead = { [weak self] in
            let read = catalog.colors.compactMapValues(\.accent)
            guard read != fileAccents else { return }
            fileAccents = read
            ThemeBridge.refresh(store: self?.services.themeStore ?? ThemeScope.app.store)
            self?.resolver.changed()
        }
        catalog.load()
        // Other sources (layout templates) keep the lists their owners installed.
        let otherSuggestions = registry.argumentSuggestions
        registry.argumentSuggestions = { source in
            source == ActionSuggestions.ghosttyThemes ? catalog.names.map { ActionEnumCase(value: $0, title: $0) } : otherSuggestions?(source) ?? []
        }
        registry.argumentValidation = { source, text in source != ActionSuggestions.ghosttyThemes || catalog.accepts(text) }
        let store = services.machines.local.store
        let terminalThemes = terminalThemes
        let local = services.machines.local
        let workspaceBackgrounds = self.workspaceBackgrounds, workspaceOpacities = self.workspaceOpacities
        Task { await workspaceBackgrounds.load() }
        Task { await workspaceOpacities.load() }
        let appearanceScopes = self.appearanceScopes
        Task { await appearanceScopes.load() }
        dayObservers = observeDayChanges()
        Task { [weak self] in
            await terminalThemes.load()
            // Once per launch, after the home daemon's first tree: drop the
            // themes of its terminals that closed while the app was away.
            for await loaded in ObservationStream({ local.store.isLoaded }) where loaded {
                self?.pruneTerminalThemes()
                return
            }
        }
        observation = Task { [weak self] in
            for await _ in ObservationStream({ () -> [String?] in
                store.profiles.map(\.theme) + store.personal.workspaces.map(\.theme)
                    + [String(describing: store.personal.terminalThemes), String(describing: terminalThemes.themes),
                       String(describing: workspaceBackgrounds.backgrounds), String(describing: workspaceOpacities.backgrounds),
                       String(describing: appearanceScopes.backgrounds),
                       String(store.identity?.supports(DaemonCapability.personalTerminals.rawValue) ?? false)]
            }) {
                self?.migrateTerminalThemes()
                self?.apply()
            }
        }
    }

    // MARK: Mounts

    /// A window opened or switched room: its room and its shown workspace take their themes.
    func windowDidChange(_ controller: WindowController) {
        setTheme(of: controller.themeScope, to: roomTheme(controller.state.profileID))
        applyWindowBackground(controller)
        if let content = controller.content { contentDidShow(content) }
    }

    /// A workspace content was created or shown in `controller`'s window: it and the terminals in
    /// its panes take the applies they missed while parked.
    func contentDidShow(_ content: WorkspaceContentController) {
        setTheme(of: content.themeScope, to: workspaceTheme(content.workspace.id))
        applyWorkspaceBackground(content)
        for pane in content.panes.values { applyPaneBackground(pane) }
        for id in content.panes.values.flatMap(\.orderedIDs) { services.cache.existingTerminal(id.rawValue).map { catchUp($0, fresh: false) } }
    }

    /// `entry` takes its theme as of the last `apply`. `fresh`: its surface was just made or
    /// presented for a tab (`TerminalTabContent`), so it takes the theme even when current, and
    /// its surface syncs (later scope changes reach it through its binding).
    func catchUp(_ entry: TerminalEntry, fresh: Bool) {
        guard applies.take(entry, fresh: fresh) else { return }
        entry.themeBinding.coordinator = self
        setTheme(of: entry.themeScope, to: terminalTheme(entry.themeKey))
        if fresh { entry.themeBinding.syncSurface(force: false) }
    }

    // MARK: Sources

    func roomTheme(_ room: ProfileID) -> String? {
        if let preview, preview.target == .room(room) { return preview.spec }
        return settled(.room(room), saved: services.machines.local.store.profile(room)?.theme)
    }

    func workspaceTheme(_ workspaceID: String) -> String? {
        if let preview, preview.target == .workspace(workspaceID) { return preview.spec }
        let saved = WindowProfiles.qualified(workspaceID, machines: services.machines).flatMap {
            services.machines.local.store.personal.workspace(session: $0.session, key: $0.key)?.theme
        }
        return settled(.workspace(workspaceID), saved: saved)
    }

    /// The pending value until the daemon reports it, then the saved one.
    func settled(_ target: ThemePreview.Target, saved: String?) -> String? {
        guard let value = pending[target] else { return saved }
        if value == saved { pending[target] = nil }
        return value
    }

    func terminalTheme(_ key: TerminalThemeKey) -> String? {
        if let preview, preview.target == .terminal(key) { return preview.spec }
        return settled(.terminal(key), saved: savedTerminalTheme(key))
    }

    /// The tab indicator of a terminal with its own theme (not one it
    /// inherits from its workspace or room). Observation-tracked.
    func badge(forTerminal key: TerminalThemeKey) -> TabThemeBadge? {
        guard let text = terminalTheme(key), let resolved = resolver.resolve(ThemeSpec(text)) else { return nil }
        return TabThemeBadge(name: resolved.spec.raw, background: resolved.input.background, foreground: resolved.input.foreground)
    }

    // MARK: Apply

    /// Re-reads every theme of what the windows show (I5): each room and each shown workspace with
    /// the terminals in its panes. A parked workspace and its terminals catch up when they show
    /// (`contentDidShow`). `forceSurfaces` (a Ghostty config reload reset the surfaces) re-applies
    /// every live surface's config at once: the config event pays for it, never a later workspace
    /// or tab switch (the perf gate's relaunch tab switches caught a config apply on the switch).
    func apply(forceSurfaces: Bool = false) {
        applies.advance()
        for controller in services.windows.controllers { windowDidChange(controller) }
        if forceSurfaces { for entry in services.cache.terminals.values { entry.themeBinding.syncSurface(force: true) } }
    }

    func setTheme(of scope: ThemeScope, to text: String?) {
        let resolved = resolver.resolve(text.flatMap(ThemeSpec.init))
        // Re-resolves run on every Ghostty config reload in the process; a
        // theme this coordinator never set is not its to clear.
        guard resolved != nil || themed.contains(scope) else { return }
        if resolved == nil { themed.remove(scope) } else { themed.add(scope) }
        scope.setOverride(resolved?.spec, input: resolved?.input)
    }

    // MARK: Commit and preview

    /// A theme action ran: show `spec` (nil: the Ghostty config) at once
    /// and end any preview. Terminal themes are saved here; room and
    /// workspace themes stay pending until the daemon echoes them.
    func commit(_ target: ThemePreview.Target, spec: String?) {
        if case .terminal(let key) = target {
            saveTerminalTheme(spec, for: key)
        } else {
            pending[target] = .some(spec)
        }
        preview = nil
        apply()
    }

    /// A picker (palette argument page, context submenu) highlighted
    /// `value` of a theme action's `theme` argument; nil ends the preview.
    func pickerPreview(_ action: ActionID, value: String?, target: ActionTargetRef?) {
        guard let value else { return endPreview() }
        guard let resolved = previewTarget?(action, target) else { return }
        beginPreview(resolved, spec: value == ActionArgument.themeConfigValue ? nil : value)
    }

    /// The `theme` value a picker shows as current for its target.
    func currentChoice(_ action: ActionID, target: ActionTargetRef?) -> String? {
        if action == "browserTheme" {
            // The page's forced color scheme (the toolbar's theme menu checks it).
            let entry = if let target, target.kind == .tab { services.cache.existingBrowser(target.id) } else {
                try? AppActionContext(services: services).page(ActionInvocation(target: target))
            }
            return entry?.chrome.toolbarButtons.modes.colorScheme.rawValue
        }
        // A pane's own background and tint (the pane's Appearance folder checks them).
        if action == "pane.setBackground" || action == "pane.setTint" {
            guard let pane = paneForChoice(target) else { return nil }
            return action == "pane.setBackground" ? ownValue(.background, of: .pane(pane)) ?? "inherit" : ownValue(.tint, of: .pane(pane)) ?? "none"
        }
        guard let resolved = previewTarget?(action, target) else { return nil }
        let current: String? = switch resolved {
        case .room(let room): roomTheme(room)
        case .workspace(let id): workspaceTheme(id)
        case .terminal(let key): terminalTheme(key)
        }
        return current ?? ActionArgument.themeConfigValue
    }

    /// Shows `spec` (nil: the Ghostty config) on `target` without saving it.
    func beginPreview(_ target: ThemePreview.Target, spec: String?) {
        let next = ThemePreview(target: target, spec: spec)
        guard next != preview else { return }
        preview = next
        apply()
    }

    /// Ends a preview; the saved themes show again.
    func endPreview() {
        guard preview != nil else { return }
        preview = nil
        apply()
    }
}

/// A theme shown while a picker highlights it.
struct ThemePreview: Equatable {
    enum Target: Hashable {
        case room(ProfileID)
        case workspace(String)
        case terminal(TerminalThemeKey)
    }

    let target: Target
    /// Nil previews the Ghostty config (the "Use Ghostty Config" row).
    let spec: String?
}

/// Keeps one terminal surface on the theme its scope is in (its own,
/// its workspace's, its room's): the scope calls it on every color change.
@MainActor
final class TerminalThemeBinding: ThemeResponsive {
    weak var coordinator: ThemeCoordinator?
    private unowned let scope: ThemeScope
    private weak var session: TerminalSession?

    // cx-qxxu: released with its terminal, which Cmd-T's New Tab page can withdraw while its
    // action runs; a main-actor deinit's hop traps there (cx-t7hu).
    nonisolated deinit {}

    init(scope: ThemeScope, session: TerminalSession) {
        self.scope = scope
        self.session = session
        scope.addResponder(self)
    }

    func themeDidChange() { syncSurface(force: false) }

    func syncSurface(force: Bool) {
        guard let session, let coordinator else { return }
        session.setTheme(coordinator.resolver.resolve(scope.effectiveSpec)?.config, force: force)
    }
}
