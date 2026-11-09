import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextBridge
import CmuxNextWindowRules

/// Appearance per window, workspace, pane and tab (plans/cmux-next/appearance-scopes-DESIGN.md):
/// `appearance.set|reset` (every level and property) and the menu rows `pane.setBackground`,
/// `pane.setTint`, `pane.clearBackground`, `workspace.setTint`, `tab.setTint`. One path for the
/// right-click menus, palette, CLI and MCP; values persist through `ThemeCoordinator`.
struct PaneBackgroundHandlers {
    let context: AppActionContext

    func bind(into registry: ActionRegistry) {
        let ctx = context
        func save(_ saved: Bool) {
            if !saved { ctx.refuse(PaneBackgroundStrings.noDurablePane) }
        }

        /// Clears `target`'s own values of the properties a reset verb names (Rust names only those set
        /// at the level).
        func reset(_ target: AppearanceTarget, _ verb: WindowRules.AppearanceVerb) -> Bool {
            (verb.properties ?? []).compactMap(AppearanceProperty.init(rawValue:))
                .allSatisfy { ctx.services.themes.setOwnValue(nil, $0, of: target) }
        }

        /// `color`: a tint, or `none` (nil inside `.some`) to reset to inherited; refuses others.
        func tint(_ invocation: ActionInvocation) -> String?? {
            let value = (invocation["color"]?.stringValue ?? "").trimmingCharacters(in: .whitespaces)
            if value == "none" { return .some(nil) }
            guard let tint = PaneTint(value) else { return ctx.refuse(PaneBackgroundStrings.badTint) }
            return .some(tint.id)
        }

        /// What `appearance.set|reset` does: the level and property it names, whether the property is
        /// set there, and which theme action a level's theme goes through (cmux-window-rules `appearance`).
        func appearanceVerb(scope: String?, property: String?, set: Bool) -> (AppearanceLevel, WindowRules.AppearanceVerb)? {
            let ask = WindowRules.AppearanceAsk(scope: scope, property: property, set: set)
            let verb = WindowRules().appearance(ask)
            guard let verb, let level = verb.level.flatMap(AppearanceLevel.init(name:)) else {
                return ctx.refuse(verb?.refusal == "notAtLevel" ? PaneBackgroundStrings.notAtLevel : PaneBackgroundStrings.badProperty)
            }
            return (level, verb)
        }

        func appearanceVerb(_ invocation: ActionInvocation, set: Bool) -> (AppearanceLevel, WindowRules.AppearanceVerb)? {
            appearanceVerb(scope: invocation["scope"]?.stringValue, property: invocation["property"]?.stringValue, set: set)
        }

        func target(_ level: AppearanceLevel, _ invocation: ActionInvocation) -> AppearanceTarget? {
            switch level {
            case .window:
                guard let profile = ctx.services.windows.active?.state.profileID ?? ctx.refuse(RefusalStrings.noWindowShowsWorkspace) else { return nil }
                return .window(profile)
            case .workspace:
                guard let id = ctx.scope(invocation).workspace?.id ?? ctx.refuse(RefusalStrings.noWindowShowsWorkspace) else { return nil }
                return .workspace(id)
            case .pane:
                return ctx.paneController(invocation).map(AppearanceTarget.pane)
            case .tab:
                guard let pane = ctx.paneController(invocation) else { return nil }
                let explicit = invocation.target.flatMap { $0.kind == .tab ? pane.tab(StripTabID($0.id)) : nil }
                guard let tab = explicit ?? pane.selectedTab ?? ctx.refuse(MiscHandlerStrings.noPane) else { return nil }
                return .tab(pane, tab)
            case .app, .rule:
                return nil
            }
        }

        registry.bind("pane.setBackground", invoke: { invocation in
            guard let pane = ctx.paneController(invocation) else { return }
            let value = (invocation["background"]?.stringValue ?? "").trimmingCharacters(in: .whitespaces)
            guard Self.acceptsBackground(value) else { return ctx.refuse(PaneBackgroundStrings.badBackground) }
            save(ctx.services.themes.setPaneBackground(value, for: pane))
        })
        registry.bind("pane.setTint", invoke: { invocation in
            guard let pane = ctx.paneController(invocation), let tint = tint(invocation) else { return }
            save(ctx.services.themes.setOwnValue(tint, .tint, of: .pane(pane)))
        })
        registry.bind("pane.clearBackground", invoke: { invocation in
            guard let pane = ctx.paneController(invocation),
                  let (_, verb) = appearanceVerb(scope: AppearanceLevel.pane.name, property: nil, set: false) else { return }
            save(reset(.pane(pane), verb))
        })
        registry.bind("workspace.setTint", invoke: { invocation in
            guard let id = ctx.scope(invocation).workspace?.id ?? ctx.refuse(RefusalStrings.noWindowShowsWorkspace),
                  let tint = tint(invocation) else { return }
            save(ctx.services.themes.setOwnValue(tint, .tint, of: .workspace(id)))
        })
        registry.bind("tab.setTint", invoke: { invocation in
            guard let target = target(.tab, invocation), let tint = tint(invocation) else { return }
            save(ctx.services.themes.setOwnValue(tint, .tint, of: target))
        })
        registry.bind("appearance.set", invoke: { invocation in
            guard let (level, verb) = appearanceVerb(invocation, set: true) else { return }
            let value = (invocation["value"]?.stringValue ?? "").trimmingCharacters(in: .whitespaces)
            let property = verb.properties?.first.flatMap(AppearanceProperty.init(rawValue:))
            guard (property ?? .theme).accepts(value) else { return ctx.refuse(PaneBackgroundStrings.badValue) }
            guard let target = target(level, invocation) else { return }
            if let forwarded = verb.themeAction {
                _ = ctx.services.registry.perform(ActionID(rawValue: forwarded), invocation: forward(invocation, theme: value))
                return
            }
            guard let property else { return }
            save(ctx.services.themes.setOwnValue(value, property, of: target))
        })
        registry.bind("appearance.reset", invoke: { invocation in
            guard let (level, verb) = appearanceVerb(invocation, set: false) else { return }
            guard let target = target(level, invocation) else { return }
            if let forwarded = verb.themeAction {
                _ = ctx.services.registry.perform(ActionID(rawValue: forwarded), invocation: forward(invocation, theme: nil))
            }
            save(reset(target, verb))
        })
    }

    private func forward(_ invocation: ActionInvocation, theme: String?) -> ActionInvocation {
        var forwarded = invocation
        forwarded.arguments = theme.map { ["theme": .string($0)] } ?? [:]
        return forwarded
    }

    /// The values `appearance.background` takes, plus `inherit`.
    static func acceptsBackground(_ value: String) -> Bool {
        value == "inherit" || value == "none" || value == BackdropSelectionSetting.dailyID || BackdropSelection(id: value) != nil
    }
}
