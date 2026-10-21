import CmuxNextActions
import CmuxNextSettings

/// Enable cmux Browser and Disable cmux Browser (palette, CLI `browser enable` / `browser
/// disable`, MCP through `action run`) set `browser.enabled`, the Settings > Browser row Enable
/// cmux Browser, so the choice follows cmux.json. Off, `BrowserTabService` opens no tab for a web
/// page and `LinkRouting` sends every link to the default browser (classic's switch,
/// e46e80b424f). The config layer is the one owner; menus show only the action that applies.
enum BrowserEnabledToggle {
    static let path = LinkRouting.enabledPath

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let enabled = { (context.services.settings?.snapshot.linkRouting ?? .fallback).browserEnabled }
        for (id, value) in [("palette.enableBrowser", true), ("palette.disableBrowser", false)] as [(ActionID, Bool)] {
            registry.bind(id, unavailable: { nil }) { _ in
                guard enabled() != value else { return }
                try AppearanceHandlers.requireUnmanaged(path, context)
                context.writeSetting("browser enabled setting", path, .bool(value))
            }
            // Menus and the palette's targets offer Enable while off and Disable while on.
            ActionTargetVisibility.hide(id, in: registry) { _ in enabled() == value }
        }
    }
}
