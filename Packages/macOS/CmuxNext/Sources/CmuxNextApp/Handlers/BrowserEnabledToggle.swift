import CmuxNextActions
import CmuxNextSettings
import os

/// Enable cmux Browser and Disable cmux Browser (palette, CLI `browser enable` / `browser
/// disable`, MCP through `action run`) set `browser.enabled`, the Settings > Browser row Enable
/// cmux Browser, so the choice follows cmux.json. Off, `BrowserTabService` opens no tab for a web
/// page and `LinkRouting` sends every link to the default browser (classic's switch,
/// e46e80b424f). The config layer is the one owner; menus show only the action that applies.
enum BrowserEnabledToggle {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.actions")
    static let path = LinkRouting.enabledPath

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let enabled = { (context.services.settings?.snapshot.linkRouting ?? .fallback).browserEnabled }
        for (id, value) in [("palette.enableBrowser", true), ("palette.disableBrowser", false)] as [(ActionID, Bool)] {
            registry.bind(id, unavailable: { nil }) { invocation in
                guard let settings = context.services.settings, enabled() != value else { return }
                try AppearanceHandlers.requireUnmanaged(path, context)
                let writer = SettingWriter(invocation.origin)
                Task {
                    guard let descriptor = SettingsSchema.descriptor(for: path) else { return }
                    do { try await settings.setSetting(descriptor, to: .bool(value), by: writer) } catch {
                        logger.error("browser enabled setting failed: \(String(describing: error), privacy: .public)")
                    }
                }
            }
            // Menus and the palette's targets offer Enable while off and Disable while on.
            ActionTargetVisibility.hide(id, in: registry) { _ in enabled() == value }
        }
    }
}
