import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextBridge
import CmuxNextBridgeUI

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

        func reset(_ target: AppearanceTarget, properties: [AppearanceProperty]) -> Bool {
            properties.filter { $0.levels.contains(target.level) }
                .allSatisfy { ctx.services.themes.setOwnValue(nil, $0, of: target) }
        }

        /// `color`: a tint, or `none` (nil inside `.some`) to reset to inherited; refuses others.
        func tint(_ invocation: ActionInvocation) -> String?? {
            let value = (invocation["color"]?.stringValue ?? "").trimmingCharacters(in: .whitespaces)
            if value == "none" { return .some(nil) }
            guard let tint = PaneTint(value) else { return ctx.refuse(PaneBackgroundStrings.badTint) }
            return .some(tint.id)
        }

        func levelAndProperty(_ invocation: ActionInvocation) -> (AppearanceLevel, AppearanceProperty?)? {
            guard let level = invocation["scope"]?.stringValue.flatMap(AppearanceLevel.init(name:)), level != .app, level != .rule else { return nil }
            guard let raw = invocation["property"]?.stringValue else { return (level, nil) }
            guard let property = AppearanceProperty(rawValue: raw) else { return nil }
            return (level, property)
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
            guard let pane = ctx.paneController(invocation) else { return }
            save(reset(.pane(pane), properties: AppearanceProperty.allCases))
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
            guard let (level, property) = levelAndProperty(invocation), let property else {
                return ctx.refuse(PaneBackgroundStrings.badProperty)
            }
            guard property.levels.contains(level) else { return ctx.refuse(PaneBackgroundStrings.notAtLevel) }
            let value = (invocation["value"]?.stringValue ?? "").trimmingCharacters(in: .whitespaces)
            guard property.accepts(value) else { return ctx.refuse(PaneBackgroundStrings.badValue) }
            guard let target = target(level, invocation) else { return }
            if property == .theme, let forwarded = Self.themeAction(level, set: true) {
                _ = ctx.services.registry.perform(forwarded, invocation: forward(invocation, theme: value))
                return
            }
            save(ctx.services.themes.setOwnValue(value, property, of: target))
        })
        registry.bind("appearance.reset", invoke: { invocation in
            guard let (level, property) = levelAndProperty(invocation) else { return ctx.refuse(PaneBackgroundStrings.badProperty) }
            guard let target = target(level, invocation) else { return }
            let properties = property.map { [$0] } ?? AppearanceProperty.allCases
            if properties.contains(.theme), let forwarded = Self.themeAction(level, set: false) {
                _ = ctx.services.registry.perform(forwarded, invocation: forward(invocation, theme: nil))
            }
            save(reset(target, properties: properties.filter { $0 != .theme || Self.themeAction(level, set: false) == nil }))
        })

    }

    /// Window, workspace and tab themes keep their own saved rows (`ThemeHandlers`): `appearance`
    /// forwards to them so there is one theme path per level.
    static func themeAction(_ level: AppearanceLevel, set: Bool) -> ActionID? {
        switch level {
        case .window: set ? "space.setTheme" : "space.clearTheme"
        case .workspace: set ? "workspace.setTheme" : "workspace.clearTheme"
        case .tab: set ? "terminal.setTheme" : "terminal.clearTheme"
        case .app, .rule, .pane: nil
        }
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
