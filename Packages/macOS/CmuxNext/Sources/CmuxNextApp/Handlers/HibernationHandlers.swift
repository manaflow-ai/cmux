import CmuxNextActions
import CmuxNextHibernation
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
        registry.bind("hibernateTab", invoke: { invocation in
            guard let (_, id) = context.tab(invocation), let hibernation = context.services.cache.hibernation else { return }
            switch hibernation.hibernateNow(id.rawValue) {
            case nil: break
            case .unsupported?: context.refuse(RefusalStrings.hibernateUnsupported)
            case .formSubmission?: context.refuse(RefusalStrings.hibernateFormSubmission)
            case _?: context.refuse(RefusalStrings.hibernateVisibleTab)
            }
        })
        registry.bind("neverHibernateSite", invoke: { invocation in
            guard let (_, id) = context.tab(invocation), let hibernation = context.services.cache.hibernation else { return }
            guard let host = hibernation.host(of: id.rawValue) else { return context.refuse(RefusalStrings.neverHibernateNoSite) }
            neverHibernate(host: host, context)
        })
        // Workspace hibernation (plans/cmux-next/workspace-hibernation-DESIGN.md).
        registry.bindEffect("workspace.hibernate") { invocation in
            guard let (model, _) = try? context.workspace(invocation) else { return .refused(RefusalStrings.noWorkspaceToActOn) }
            do { try context.services.workspaceHibernation.hibernateNow(model.id) } catch { return .refused(WorkspaceHibernationActionStrings.shownRefusal) }
            return .done
        }
        registry.bindEffect("workspace.toggleKeepAwake") { invocation in
            guard let (model, _) = try? context.workspace(invocation) else { return .refused(RefusalStrings.noWorkspaceToActOn) }
            context.services.workspaceHibernation.toggleKeepAwake(model.id)
            return .done
        }
        ActionTargetTitles.set("workspace.toggleKeepAwake", in: registry) { invocation in
            guard let (model, _) = try? context.workspace(invocation) else { return nil }
            return context.services.workspaceHibernation.keepAwake.contains(model.id)
                ? WorkspaceHibernationActionStrings.allowHibernation : WorkspaceHibernationActionStrings.keepAwake
        }
        registry.bind("wakeTab", invoke: { invocation in
            guard let (_, id) = context.tab(invocation), let hibernation = context.services.cache.hibernation else { return }
            if !hibernation.wake(id.rawValue) { context.refuseQuietly(RefusalStrings.wakeNotHibernated) }
        })
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
            // The person chose a timeout: hidden pages are discarded on their own from now on.
            setting.discardsAutomatically = true
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
