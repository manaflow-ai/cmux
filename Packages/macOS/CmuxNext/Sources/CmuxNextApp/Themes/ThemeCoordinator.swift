import AppKit
import CmuxNextActions
import CmuxNextBrowser
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
    /// The scopes whose theme this coordinator set.
    private let themed = NSHashTable<ThemeScope>.weakObjects()

    init(services: AppServices, terminalThemes: TerminalThemeStore) {
        self.services = services
        self.terminalThemes = terminalThemes
        resolver.onChange = { [weak self] in
            self?.apply(forceSurfaces: true)
            self?.applyChromeTheme()
        }
    }

    // MARK: App theme (appearance.appTheme)

    /// `appearance.appTheme` as last read; nil follows the terminal theme.
    private var chromeTheme: String?
    private var chromeObservation: Task<Void, Never>?

    /// Follows `appearance.appTheme`: the app theme pages get (`--cmux-app-*`, `WebTheme`),
    /// resolved like the other theme levels (the variant for the system appearance, the user's
    /// explicit config colors over it). `followTerminal` leaves each scope on its own theme.
    func followChromeTheme(_ settings: SettingsController) {
        chromeTheme = settings.snapshot.chromeTheme
        applyChromeTheme()
        chromeObservation = Task { [weak self] in
            for await theme in Observations({ settings.snapshot.chromeTheme }) {
                guard let self, theme != self.chromeTheme else { continue }
                self.chromeTheme = theme
                self.applyChromeTheme()
            }
        }
    }

    private func applyChromeTheme() {
        let resolved = chromeTheme.flatMap(ThemeSpec.init).flatMap(resolver.resolve)
        ThemeStore.shared.setAppTheme(resolved.map { AppTheme.derive(from: $0.input) })
    }

    func start() {
        let registry = services.registry
        registry.choicePreview = { [weak self] action, _, value, target in
            self?.pickerPreview(action, value: value, target: target)
        }
        registry.choiceState = { [weak self] action, target in self?.currentChoice(action, target: target) }
        catalog.load()
        let catalog = catalog
        registry.argumentSuggestions = { source in
            source == ActionSuggestions.ghosttyThemes ? catalog.names.map { ActionEnumCase(value: $0, title: $0) } : []
        }
        registry.argumentValidation = { source, text in source != ActionSuggestions.ghosttyThemes || catalog.accepts(text) }
        let store = services.machines.local.store
        let terminalThemes = terminalThemes
        let local = services.machines.local
        Task { [weak self] in
            await terminalThemes.load()
            // Once per launch, after the home daemon's first tree: drop the
            // themes of its terminals that closed while the app was away.
            for await loaded in Observations({ local.store.isLoaded }) where loaded {
                self?.pruneTerminalThemes()
                return
            }
        }
        observation = Task { [weak self] in
            for await _ in Observations({ () -> [String?] in
                store.profiles.map(\.theme) + store.personal.workspaces.map(\.theme)
                    + [String(describing: store.personal.terminalThemes), String(describing: terminalThemes.themes),
                       String(store.identity?.supports(DaemonCapabilities.shared.personalTerminals) ?? false)]
            }) {
                self?.migrateTerminalThemes()
                self?.apply()
            }
        }
    }

    // MARK: Mounts

    /// A window opened or switched room.
    func windowDidChange(_ controller: WindowController) {
        setTheme(of: controller.themeScope, to: roomTheme(controller.state.profileID))
    }

    /// A workspace content was created or shown in `controller`'s window.
    func contentDidShow(_ content: WorkspaceContentController) {
        setTheme(of: content.themeScope, to: workspaceTheme(content.workspace.id))
    }

    /// A terminal surface was created for a tab.
    func terminalDidMount(_ entry: TerminalEntry) {
        entry.themeBinding.coordinator = self
        setTheme(of: entry.themeScope, to: terminalTheme(entry.themeKey))
        entry.themeBinding.syncSurface(force: false)
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

    /// Re-reads every theme. `forceSurfaces` re-applies surface configs
    /// even when unchanged (after a Ghostty config reload reset them).
    func apply(forceSurfaces: Bool = false) {
        for controller in services.windows.controllers {
            windowDidChange(controller)
            for content in controller.mountedContents { contentDidShow(content) }
        }
        for entry in services.cache.terminals.values.map({ $0 }) {
            entry.themeBinding.coordinator = self
            setTheme(of: entry.themeScope, to: terminalTheme(entry.themeKey))
            if forceSurfaces { entry.themeBinding.syncSurface(force: true) }
        }
    }

    private func setTheme(of scope: ThemeScope, to text: String?) {
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
