import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDesign
import Foundation

/// Appearance per window, workspace, pane and tab (plans/cmux-next/appearance-scopes-DESIGN.md).
/// Window, workspace and terminal themes and workspace backgrounds keep their own stores; every
/// other value lives in one app-local store (`appearance-scopes.json`) keyed
/// `<level>:<durable id>|<property>`, so it follows a moved pane or workspace and survives relaunch.
extension ThemeCoordinator {
    // MARK: Keys

    /// The durable key of a place, or nil when its session gives it no durable id (an old daemon).
    func scopeKey(_ target: AppearanceTarget) -> String? {
        switch target {
        case .window(let profile):
            return "window:\(profile.rawValue)"
        case .workspace(let id):
            return workspaceBackgroundKey(id).map { "workspace:\($0)" }
        case .pane(let pane):
            guard let session = pane.daemon.store.registryID, let resource = pane.pane.resourceID?.rawValue else { return nil }
            return "pane:\(session)/\(resource)"
        case .tab(let pane, let tab):
            guard let session = pane.daemon.store.registryID, let resource = tab.resourceID?.rawValue else { return nil }
            return "tab:\(session)/\(resource)"
        }
    }

    /// The value `target` sets for `property` itself (nil: it inherits).
    func ownValue(_ property: AppearanceProperty, of target: AppearanceTarget) -> String? {
        switch (property, target) {
        case (.theme, .window(let profile)): return roomTheme(profile)
        case (.theme, .workspace(let id)): return workspaceTheme(id)
        case (.background, .workspace(let id)): return workspaceBackground(id)
        case (.opacity, .workspace(let id)): return workspaceOpacity(id).map { String($0) }
        default: return scopeKey(target).flatMap { appearanceScopes.background(for: "\($0)|\(property.rawValue)") }
        }
    }

    /// Saves (or with nil, resets to inherited) `property` on `target`, then re-applies.
    ///
    /// - Returns: False when the place has no durable id to save it under.
    @discardableResult
    func setOwnValue(_ value: String?, _ property: AppearanceProperty, of target: AppearanceTarget) -> Bool {
        switch (property, target) {
        case (.background, .workspace(let id)):
            setWorkspaceBackground(value, for: id)
            return true
        case (.opacity, .workspace(let id)):
            setWorkspaceOpacity(value.flatMap(Double.init), for: id)
            return true
        default:
            guard let key = scopeKey(target) else { return false }
            appearanceScopes.set(value, for: "\(key)|\(property.rawValue)")
            apply()
            return true
        }
    }

    // MARK: Cascade

    /// Every level's own values for what `pane` shows (app values come from their settings and
    /// are not listed here: a missing value means "the app's").
    func cascade(for pane: PaneController) -> AppearanceCascade {
        var cascade = AppearanceCascade()
        var targets: [AppearanceTarget] = [.pane(pane)]
        if let profile = pane.state?.profileID { targets.insert(.window(profile), at: 0) }
        if let workspace = pane.workspace?.workspace.id { targets.insert(.workspace(workspace), at: targets.count - 1) }
        if let tab = pane.selectedTab { targets.append(.tab(pane, tab)) }
        for target in targets {
            for property in AppearanceProperty.allCases where property.levels.contains(target.level) {
                if let value = ownValue(property, of: target) { cascade.set(property, value, at: target.level) }
            }
        }
        return cascade
    }

    // MARK: Apply

    /// Gives `pane` its own background, theme, glass tint and the marker tint in effect for it.
    func applyPaneBackground(_ pane: PaneController) {
        // Nothing stored anywhere below the app: the common case does no work.
        guard !appearanceScopes.backgrounds.isEmpty || pane.view.backdropState.hasOwnValues else { return }
        let own = { (property: AppearanceProperty) in self.ownValue(property, of: .pane(pane)) }
        let tab = pane.selectedTab.flatMap { tab in self.scopeKey(.tab(pane, tab)) }
        let tint = (tab.flatMap { appearanceScopes.background(for: "\($0)|tint") } ?? own(.tint)
            ?? pane.workspace.flatMap { ownValue(.tint, of: .workspace($0.workspace.id)) }
            ?? pane.state.flatMap { ownValue(.tint, of: .window($0.profileID)) }).flatMap(PaneTint.init)
        pane.view.setPaneBackground(pin: WorkspaceBackgroundStore.pin(own(.background), now: Date()), tint: tint,
                                    glass: own(.opacity).flatMap(Double.init))
        setTheme(of: pane.view.paneScope, to: own(.theme))
    }

    /// A window's own background and glass tint over its room scope (a workspace's own still wins
    /// while it shows).
    func applyWindowBackground(_ controller: WindowController) {
        let window = AppearanceTarget.window(controller.state.profileID)
        guard let key = scopeKey(window) else { return }
        let background = appearanceScopes.background(for: "\(key)|background")
        controller.themeScope.pinBackdrop(WorkspaceBackgroundStore.pin(background, now: Date()))
        controller.themeScope.pinBackdropTint(appearanceScopes.background(for: "\(key)|opacity").flatMap(Double.init))
    }

    // MARK: Pane shortcuts (pane.setBackground)

    @discardableResult
    func setPaneBackground(_ value: String?, for pane: PaneController) -> Bool {
        setOwnValue(value == "inherit" ? nil : value, .background, of: .pane(pane))
    }

    /// The pane a choice menu or picker shows its check for: the target pane, else the focused one.
    /// Never refuses (a menu's state query must not post a refusal).
    func paneForChoice(_ target: ActionTargetRef?) -> PaneController? {
        guard let target, target.kind == .pane else { return services.windows.active?.focusedPane }
        for controller in services.windows.controllers {
            for content in controller.mountedContents {
                if let pane = content.panes.values.first(where: { $0.paneKey == target.id }) { return pane }
            }
        }
        return nil
    }
}
