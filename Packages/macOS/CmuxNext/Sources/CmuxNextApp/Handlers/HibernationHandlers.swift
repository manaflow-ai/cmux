import CmuxNextActions
import CmuxNextSettings
import os

/// `browser.hibernation` settings and the per-tab Hibernate / Wake
/// commands (plans/cmux-next/tab-lifecycle.md). The setting applies at
/// once, then is written to cmux.json; the watcher reapplies the same value.
enum HibernationHandlers {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.actions")

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("browser.hibernation.off", run: { _ in set(.off, context) })
        registry.bind("browser.hibernation.moderate", run: { _ in set(.moderate, context) })
        registry.bind("browser.hibernation.aggressive", run: { _ in set(.aggressive, context) })
        registry.bind("hibernateTab", invoke: { invocation in
            guard let (_, id) = context.tab(invocation), let hibernation = context.services.cache.hibernation else { return }
            switch hibernation.hibernateNow(id.rawValue) {
            case nil: break
            case .unsupported?: context.refuse(RefusalStrings.hibernateUnsupported)
            case _?: context.refuse(RefusalStrings.hibernateVisibleTab)
            }
        })
        registry.bind("wakeTab", invoke: { invocation in
            guard let (_, id) = context.tab(invocation), let hibernation = context.services.cache.hibernation else { return }
            if !hibernation.wake(id.rawValue) { context.refuse(RefusalStrings.wakeNotHibernated) }
        })
    }

    private static func set(_ mode: BrowserHibernationSetting.Mode, _ context: AppActionContext) {
        let services = context.services
        if let hibernation = services.cache.hibernation {
            var setting = hibernation.setting
            setting.mode = mode
            hibernation.apply(setting)
        }
        guard let settings = services.settings else { return }
        Task {
            do { try await settings.setBrowserHibernation(mode) } catch {
                logger.error("set browser.hibernation failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
