import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDesign

/// Set / Reset Room, Workspace and Terminal Theme
/// (plans/cmux-next/data-model.md 6). Room and workspace themes are
/// personal rows of the home daemon (`profiles-v1`); terminal themes stay on
/// this Mac (`TerminalThemeStore`). Every entrypoint (palette, context
/// menus, CLI, shortcuts, Settings) runs these handlers; the pickers preview
/// through `ThemeCoordinator` first.
enum ThemeHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let local: @MainActor () -> DaemonService? = { context.services.machines.local }
        func personal(_ id: ActionID, _ run: @escaping @MainActor (ActionInvocation) throws -> Void) {
            registry.bind(id, requires: DaemonCapabilities.profiles, daemon: local(), run: { invocation in
                try context.requireRooms()
                try run(invocation)
            })
        }
        personal("room.setTheme") { invocation in
            try setRoom(try context.room(invocation).id, to: try spec(invocation), context)
        }
        personal("room.clearTheme") { invocation in
            try setRoom(try context.room(invocation).id, to: nil, context)
        }
        personal("workspace.setTheme") { invocation in
            try setWorkspace(invocation, to: try spec(invocation), context)
        }
        personal("workspace.clearTheme") { invocation in
            try setWorkspace(invocation, to: nil, context)
        }
        registry.bind("terminal.setTheme", run: { invocation in
            try setTerminal(invocation, to: try spec(invocation), context)
        })
        registry.bind("terminal.clearTheme", run: { invocation in
            try setTerminal(invocation, to: nil, context)
        })
        context.services.themes.previewTarget = { action, target in previewTarget(action, target, context) }
    }

    /// What a theme action would act on, without running it (pickers).
    private static func previewTarget(_ action: ActionID, _ target: ActionTargetRef?, _ context: AppActionContext) -> ThemePreview.Target? {
        let invocation = ActionInvocation(target: target)
        switch action {
        case "room.setTheme": return (try? context.room(invocation)).map { .room($0.id) }
        case "workspace.setTheme": return (try? context.workspace(invocation)).map { .workspace($0.model.id) }
        case "terminal.setTheme":
            guard let (pane, id) = context.tab(invocation), pane.tab(id)?.kind != .browser else { return nil }
            return .terminal(TerminalThemeStore.key(machine: pane.daemon.machineID, tab: id.rawValue))
        default: return nil
        }
    }

    /// The `theme` argument as a spec; nil for "Use Ghostty Config".
    private static func spec(_ invocation: ActionInvocation) throws -> String? {
        guard let raw = invocation["theme"]?.stringValue, let parsed = ThemeSpec(raw) else {
            throw ActionFailure.invalidTarget(RefusalStrings.themeMustBeOneOf(([ActionArgument.themeConfigValue] + ActionArgument.curatedThemes).joined(separator: ", ")))
        }
        return parsed.raw == ActionArgument.themeConfigValue ? nil : parsed.raw
    }

    private static func setRoom(_ room: ProfileID, to spec: String?, _ context: AppActionContext) throws {
        context.services.themes.commit(.room(room), spec: spec)
        let update: FieldUpdate<String> = spec.map { .set($0) } ?? .clear
        RoomHandlers.update(room, context) { try await $0.updateProfile($1, theme: update) }
    }

    private static func setWorkspace(_ invocation: ActionInvocation, to spec: String?, _ context: AppActionContext) throws {
        let (model, _) = try context.workspace(invocation)
        guard let qualified = WindowProfiles.qualified(model.id, machines: context.services.machines) else {
            throw ActionFailure.invalidTarget(RefusalStrings.noWorkspaceToActOn)
        }
        context.services.themes.commit(.workspace(model.id), spec: spec)
        let update: FieldUpdate<String> = spec.map { .set($0) } ?? .clear
        context.services.machines.local.send("set-personal-workspace") {
            try await $0.setPersonalWorkspace(SetPersonalWorkspaceRequest(
                sessionID: qualified.session, workspaceKey: WorkspaceKey(rawValue: qualified.key), theme: update))
        }
    }

    private static func setTerminal(_ invocation: ActionInvocation, to spec: String?, _ context: AppActionContext) throws {
        guard let (pane, id) = context.tab(invocation) else { return }
        guard pane.tab(id)?.kind != .browser else { throw ActionFailure.invalidTarget(RefusalStrings.notATerminal) }
        let key = TerminalThemeStore.key(machine: pane.daemon.machineID, tab: id.rawValue)
        context.services.themes.commit(.terminal(key), spec: spec)
    }
}

extension RefusalStrings {
    static func themeMustBeOneOf(_ choices: String) -> String {
        format("handlers.refusal.themeMustBeOneOf", "theme must be one of %@", choices)
    }
}
