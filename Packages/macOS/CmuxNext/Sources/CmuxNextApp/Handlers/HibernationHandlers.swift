import CmuxNextActions
import CmuxNextCompat
import CmuxNextFeatures
import CmuxNextHibernation
import CmuxNextMemory
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
        for radius in BrowserHibernationSetting.neighborRadiusRange {
            registry.bind(ActionID(rawValue: "browser.keepNeighborTabsAwake.\(radius)"), run: { _ in setNeighbors(radius, context) })
        }
        bindMemorySaver(into: registry, context: context)
        registry.bind("hibernateTab", invoke: { invocation in
            guard let (_, id) = context.tab(invocation), let hibernation = context.services.cache.hibernation else { return }
            switch hibernation.hibernateNow(id.rawValue) {
            case nil: break
            case .unsupported?: context.refuse(RefusalStrings.hibernateUnsupported)
            case .formSubmission?: context.refuse(RefusalStrings.hibernateFormSubmission)
            case .discardAttempted?: context.refuse(RefusalStrings.hibernateDiscardAttempted)
            case _?: context.refuse(RefusalStrings.hibernateVisibleTab)
            }
        })
        registry.bind("neverHibernateSite", invoke: { invocation in
            guard let (_, id) = context.tab(invocation), let hibernation = context.services.cache.hibernation else { return }
            guard let host = hibernation.host(of: id.rawValue) else { return context.refuse(RefusalStrings.neverHibernateNoSite) }
            neverHibernate(host: host, context)
        })
        registry.bind("wakeTab", invoke: { invocation in
            guard let (_, id) = context.tab(invocation), let hibernation = context.services.cache.hibernation else { return }
            // Only a person's run skips the wake admission; the CLI's, MCP's or a script's takes a slot.
            switch hibernation.wake(id.rawValue, origin: invocation.origin) {
            case .notHibernated: context.refuseQuietly(RefusalStrings.wakeNotHibernated)
            case .deferred: context.refuse(BrowserPageStrings.wakeDeferred)
            case .started, .queued: break
            }
        })
    }

    /// `memory.saver.<mode>`, behind `memorySaverSetting`: the coordinator takes the
    /// mode in the action's turn and the validated settings write runs after it. A failed write puts
    /// the previous mode back (the effect's rollback) and reloads Settings, so the coordinator,
    /// cmux-next.json and Settings agree again; settings not loaded yet refuse before anything changes.
    private static func bindMemorySaver(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        MemorySaverSetting.bindActions(into: registry, unavailable: {
            services.features.isEnabled(.memorySaverSetting) ? nil : MemorySaverSetting.featureOffReason
        }, refusal: { path in
            guard let settings = services.settings else { return RefusalStrings.settingsNotLoaded }
            return settings.managedKey(forPath: path).map { RefusalStrings.settingManaged($0.key) }
        }, write: { path, value in
            let settings = services.settings
            // The run's origin, read in its turn: a socket or page run may change only agent-settable keys.
            let writer = SettingWriter.currentRun()
            return {
                guard let settings else { return ActionWorkFailure(RefusalStrings.settingsNotLoaded) }
                do {
                    try await settings.setSetting(at: path, to: value, by: writer)
                    return nil
                } catch {
                    logger.error("set memory.saver failed: \(String(describing: error), privacy: .public)")
                    await settings.reload()
                    return ActionWorkFailure(String(describing: error))
                }
            }
        }, current: { services.memoryCoordinator.mode }, apply: { services.memoryCoordinator.mode = $0 })
    }

    /// Adds `host` to `browser.hibernationExclusions`: applies at once (a hibernated page of it
    /// stays as it is until shown), then writes cmux.json.
    private static func neverHibernate(host: String, _ context: AppActionContext) {
        let services = context.services
        if let hibernation = services.cache.hibernation {
            hibernation.apply(hibernation.setting.addingExclusion(host: host))
        }
        guard let settings = services.settings else { return }
        Task {
            do { try await settings.addBrowserHibernationExclusion(host: host) } catch {
                logger.error("add browser.hibernationExclusions failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// `browser.keepNeighborTabsAwake`: applies at once, then writes cmux.json.
    private static func setNeighbors(_ radius: Int, _ context: AppActionContext) {
        let services = context.services
        if let hibernation = services.cache.hibernation {
            var setting = hibernation.setting
            setting.neighborRadius = radius
            hibernation.apply(setting)
        }
        guard let settings = services.settings else { return }
        Task {
            do { try await settings.setKeepNeighborTabsAwake(radius) } catch {
                logger.error("set browser.keepNeighborTabsAwake failed: \(String(describing: error), privacy: .public)")
            }
        }
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
