import CmuxNextActions
import CmuxNextSettings
import CmuxNextSidebar

/// Projects hides from its header's menu and comes back from the sidebar's
/// menu or Settings (`sidebar.showProjects`; Leo 2026-10-06). All chats left
/// the sidebar for the New Tab page (cx-n0i9): Hide Section on its old header
/// still turns off `sidebar.showChats` (Show All Chats on New Tab), but Show
/// Hidden Sections brings back only sidebar sections. Each is a setting, so
/// the choice follows cmux.json.
enum SidebarHiddenSections {
    /// The rows a section header's menu leaves out. Every hideable header
    /// (Recents and each app section) shows the same one row, Hide <Section>
    /// (`sidebar.section.hide`, cx-w1r5: one visibility path everywhere); the
    /// app item row Hide stays on items only. An item section the user made
    /// has no hidden state, so it offers Remove Section instead.
    static func headerMenuRemovals(_ id: LayoutSectionID, isApp: Bool) -> Set<ActionID> {
        var removed: Set<ActionID> = ["sidebar.item.hideApp"]
        // An app section holds no workspaces.
        if isApp { removed.formUnion(["sidebar.section.closeWorkspaces", "sidebar.section.newWorkspace"]) }
        if !isApp && id != SidebarLayoutDocument.recentsSectionID { removed.insert("sidebar.section.hide") }
        return removed
    }

    /// Hide Section on `target` hides Recents: the Recents header, or the
    /// palette with no target. Read by id, so it works while the daemon
    /// has no sidebar layout (the sidebar draws the defaults then).
    static func hidesRecents(_ target: ActionTargetRef?) -> Bool {
        guard let target else { return true }
        return target.id == SidebarLayoutDocument.recentsSectionID.rawValue
    }

    /// The setting Hide Section turns off.
    static let hidePath = SidebarSectionsSetting.showChatsPath
    /// The settings Show Hidden Sections turns back on: Projects (All chats is no sidebar section).
    static let showHiddenPaths = [SidebarSectionsSetting.showProjectsPath]

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let settings = { context.services.settings?.snapshot.sidebarSections ?? .defaults }
        // One handler for every section's Hide; each kind keeps its one
        // owner: Recents is the `sidebar.showChats` setting, an app section
        // is its app's hidden flag on the app platform (forwarded through
        // `sidebar.item.hideApp`, the same `app.hide` path as the item row).
        registry.bind("sidebar.section.hide", unavailable: { nil }) { [weak registry] invocation in
            if hidesRecents(invocation.target) {
                guard settings().showChats else { throw ActionFailure(message: SidebarSectionStrings.alreadyHidden) }
                return try write([(hidePath, false)], invocation, context)
            }
            guard try SidebarSectionResolve.owningApp(invocation.target, in: context.services.sidebarLayout.document) != nil, let registry else {
                throw ActionFailure(message: SidebarSectionStrings.cannotHide)
            }
            _ = registry.perform("sidebar.item.hideApp", invocation: invocation)
        }
        SidebarSectionMenuTitles.bind(into: registry, context: context)
        registry.bind("sidebar.projects.hide", unavailable: { settings().showProjects ? nil : SidebarSectionStrings.alreadyHidden }) { invocation in
            try write([(SidebarSectionsSetting.showProjectsPath, false)], invocation, context)
        }
        registry.bind("sidebar.sections.showHidden", unavailable: {
            settings().showProjects ? SidebarSectionStrings.noneHidden : nil
        }) { invocation in
            try write(showHiddenPaths.map { ($0, true) }, invocation, context)
        }
        bindBand(into: registry, context: context)
        bindNoFade(into: registry, context: context)
    }

    /// `sidebar.noFade`: Show Whole Sidebar (No Fade) while the edges fade, Restore Sidebar Fade
    /// while they do not. Each writes the setting, so cmux.json and Settings show the same switch.
    private static func bindNoFade(into registry: ActionRegistry, context: AppActionContext) {
        let noFade = { @MainActor @Sendable in context.services.settings?.snapshot.sidebarSections.noFade ?? false }
        registry.bindEffect("sidebar.noFade.on") { invocation in writeNoFade(true, invocation, context) }
        registry.bindEffect("sidebar.noFade.off") { invocation in writeNoFade(false, invocation, context) }
        ActionTargetVisibility.hide("sidebar.noFade.on", in: registry) { _ in noFade() }
        ActionTargetVisibility.hide("sidebar.noFade.off", in: registry) { _ in !noFade() }
    }

    /// Writes `sidebar.noFade` on the input's turn; a refused write (a managed key) reports why.
    private static func writeNoFade(_ on: Bool, _ invocation: ActionInvocation, _ context: AppActionContext) -> ActionEffect {
        do {
            try write([(SidebarSectionsSetting.noFadePath, on)], invocation, context)
            return .done
        } catch let failure as ActionFailure {
            return .refused(failure.message)
        } catch {
            return .refused(error.localizedDescription)
        }
    }

    /// The bottom band's pieces (cx-wab7m): Hide on the piece's own menu while it shows, Show on
    /// the band's menu while it is hidden. Hide Profile Button is on the profile button's menu only.
    private static func bindBand(into registry: ActionRegistry, context: AppActionContext) {
        let settings = { @MainActor @Sendable in context.services.settings?.snapshot.sidebarSections ?? .defaults }
        let isProfileButton = { @MainActor @Sendable (target: ActionTargetRef?) -> Bool in
            guard let target else { return true }
            let id = LayoutItemID(target.id)
            return id == profileButtonID || context.services.sidebarLayout.document.item(id)?.ref == .builtIn(.account)
        }
        let pieces: [(hide: ActionID, show: ActionID, path: [String], shown: @MainActor @Sendable () -> Bool, offered: @MainActor @Sendable (ActionTargetRef?) -> Bool)] = [
            ("sidebar.spaces.hide", "sidebar.spaces.show", SidebarSectionsSetting.showSpacesPath, { settings().showSpaces }, { _ in true }),
            ("sidebar.profileControl.hide", "sidebar.profileControl.show", SidebarSectionsSetting.showProfileControlPath,
             { settings().showProfileControl }, isProfileButton),
        ]
        for piece in pieces {
            registry.bind(piece.hide, unavailable: { piece.shown() ? nil : SidebarSectionStrings.alreadyHidden }) { invocation in
                try write([(piece.path, false)], invocation, context)
            }
            registry.bind(piece.show, unavailable: { piece.shown() ? SidebarSectionStrings.noneHidden : nil }) { invocation in
                try write([(piece.path, true)], invocation, context)
            }
            ActionTargetVisibility.hide(piece.hide, in: registry) { !piece.shown() || !piece.offered($0.target) }
            ActionTargetVisibility.hide(piece.show, in: registry) { _ in piece.shown() }
        }
    }

    /// The default layout's profile button (`SidebarLayoutDocument`'s footer account item).
    static let profileButtonID = LayoutItemID("itm_account")

    /// Writes each toggle through the settings schema (managed keys refuse).
    private static func write(_ values: [([String], Bool)], _ invocation: ActionInvocation, _ context: AppActionContext) throws {
        for (path, _) in values { try AppearanceHandlers.requireUnmanaged(path, context) }
        context.writeSettings("sidebar section setting", values.map { ($0.0, JSONValue.bool($0.1)) })
    }
}
