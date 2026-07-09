import CmuxSettings
import Foundation

/// Applies the live runtime side effects of a managed-defaults apply.
///
/// `CmuxSettingsFileStore` resolves cmux.json, writes managed values into
/// `UserDefaults`, and accumulates a `ManagedDefaultBatchSideEffects` describing
/// which defaults changed. This owner replays that batch into the running app:
/// it fires each setting domain's change notification and drives the live
/// appearance/language/app-icon appliers. The app-target setting catalogs it
/// switches on (`TerminalScrollBarSettings`, `TerminalCopyOnSelectSettings`,
/// `AgentSessionAutoResumeSettings`, `AgentHibernationSettings`,
/// `RendererRealizationSettings`, `AppearanceSettings`, the `AppCatalogSection`
/// language/app-icon keys) keep this app-side rather than in `CmuxSettings`.
///
/// Isolation: this is intentionally NOT `@MainActor`.
/// ``applyManagedDefaultBatchSideEffects(_:)`` is invoked from the store's
/// non-isolated reload/apply paths and may run off the main thread, so it
/// preserves the legacy guard of dispatching its mutation block onto the main
/// thread itself (`Thread.isMainThread ? apply() : DispatchQueue.main.async`).
/// Annotating the type `@MainActor` would force its non-isolated store callers
/// to hop, changing behavior; the off-main self-dispatch is the faithful seam.
final class ManagedDefaultSideEffectApplier {
    private let notificationCenter: NotificationCenter
    private let appearanceEnvironment: AppearanceSettings.LiveApplyEnvironment

    init(
        notificationCenter: NotificationCenter,
        appearanceEnvironment: AppearanceSettings.LiveApplyEnvironment
    ) {
        self.notificationCenter = notificationCenter
        self.appearanceEnvironment = appearanceEnvironment
    }

    func applyLaunchManagedDefaultSideEffects(
        _ sideEffects: ManagedDefaultBatchSideEffects
    ) -> ManagedDefaultBatchSideEffects {
        var deferredSideEffects = ManagedDefaultBatchSideEffects()
        for change in sideEffects.changes {
            if change.defaultsKey == AppearanceSettings.appearanceModeKey {
                AppearanceSettings.applyStoredMode(
                    rawValue: UserDefaults.standard.string(forKey: change.defaultsKey),
                    source: change.source,
                    duringLaunch: true,
                    synchronizeTerminalTheme: false,
                    environment: appearanceEnvironment
                )
            } else {
                deferredSideEffects.append(
                    defaultsKey: change.defaultsKey,
                    source: change.source,
                    synchronizeAppearanceTerminalTheme: change.synchronizeAppearanceTerminalTheme
                )
            }
        }
        return deferredSideEffects
    }

    func applyManagedDefaultBatchSideEffects(_ sideEffects: ManagedDefaultBatchSideEffects) {
        guard !sideEffects.isEmpty else { return }
        let notificationCenter = notificationCenter
        let changes = sideEffects.changes
        let apply = {
            var agentSessionAutoResumeDidChange = false
            var agentHibernationDidChange = false
            var rendererRealizationDidChange = false
            for change in changes {
                if change.defaultsKey == TerminalScrollBarSettings.showScrollBarKey {
                    TerminalScrollBarSettings.notifyDidChange(notificationCenter: notificationCenter)
                }

                if change.defaultsKey == TerminalCopyOnSelectSettings.copyOnSelectKey {
                    TerminalCopyOnSelectSettings.notifyDidChange(notificationCenter: notificationCenter)
                }

                if change.defaultsKey == AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey {
                    agentSessionAutoResumeDidChange = true
                }
                if change.defaultsKey == AgentHibernationSettings.enabledKey ||
                    change.defaultsKey == AgentHibernationSettings.idleSecondsKey ||
                    change.defaultsKey == AgentHibernationSettings.maxLiveTerminalsKey ||
                    change.defaultsKey == AgentHibernationSettings.confirmationSecondsKey {
                    agentHibernationDidChange = true
                }
                if change.defaultsKey == RendererRealizationSettings.enabledKey ||
                    change.defaultsKey == RendererRealizationSettings.idleSecondsKey ||
                    change.defaultsKey == RendererRealizationSettings.maxWarmRenderersKey {
                    rendererRealizationDidChange = true
                }

                if change.defaultsKey == AppCatalogSection().language.userDefaultsKey {
                    let rawValue = UserDefaults.standard.string(forKey: change.defaultsKey) ?? ""
                    LanguageSettingsStore(defaults: .standard).applyLanguageOverride(AppLanguage(rawValue: rawValue) ?? .system)
                } else if change.defaultsKey == AppearanceSettings.appearanceModeKey {
                    AppearanceSettings.applyStoredMode(
                        rawValue: UserDefaults.standard.string(forKey: change.defaultsKey),
                        source: change.source,
                        duringLaunch: !change.synchronizeAppearanceTerminalTheme,
                        synchronizeTerminalTheme: change.synchronizeAppearanceTerminalTheme,
                        environment: self.appearanceEnvironment
                    )
                } else if change.defaultsKey == AppCatalogSection().appIcon.userDefaultsKey {
                    // `apply` runs only on the main thread (gated below), so the
                    // `@MainActor` applier is safe to enter here.
                    MainActor.assumeIsolated { appIconApplier.applyResolvedMode() }
                }
            }

            if agentSessionAutoResumeDidChange {
                AgentSessionAutoResumeSettings.notifyDidChange(notificationCenter: notificationCenter)
            }
            if agentHibernationDidChange {
                AgentHibernationSettings.notifyDidChange(notificationCenter: notificationCenter)
            }
            if rendererRealizationDidChange {
                RendererRealizationSettings.notifyDidChange(notificationCenter: notificationCenter)
            }
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async { apply() }
        }
    }
}
