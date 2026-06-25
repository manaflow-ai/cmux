import Foundation

/// Opt-in settings for crash / update session recovery, mirroring the shape of
/// ``AgentSessionAutoResumeSettings`` (UserDefaults-backed, set via `cmux.json`).
///
/// These gate behavior layered on top of cmux's existing auto-resume-on-restore
/// (`terminal.autoResumeAgentSessions`, on by default):
///   - `offerResumeAfterCrash`  — show the "you crashed, resume?" launch offer
///     after an unclean shutdown (see `UncleanShutdownSentinel`, the offer UI).
///   - `injectResumeBreadcrumb` — inject the name-anchored "pick up where we left
///     off" prompt (see `ResumeBreadcrumbBuilder`) when resuming.
///   - `resumeAgentsAfterUpdate` — after an *intentional* update/relaunch, also
///     auto-resume agents (windows always restore regardless; this only governs
///     the breadcrumb-driven agent resume).
///
/// All three default to `false`: window restore already happens, and both
/// launch-time prompting and injecting text into agents are behaviors the user
/// must explicitly enable. The cmux.json keys live under the `terminal` section
/// alongside `autoResumeAgentSessions` (see `TerminalSettingsFileMapping`).
enum CrashRecoverySettings {
    static let offerResumeAfterCrashKey = "crashRecovery.offerResumeAfterCrash"
    static let injectResumeBreadcrumbKey = "crashRecovery.injectResumeBreadcrumb"
    static let resumeAgentsAfterUpdateKey = "crashRecovery.resumeAgentsAfterUpdate"

    static let defaultOfferResumeAfterCrash = false
    static let defaultInjectResumeBreadcrumb = false
    static let defaultResumeAgentsAfterUpdate = false

    static func offerResumeAfterCrash(defaults: UserDefaults = .standard) -> Bool {
        boolValue(forKey: offerResumeAfterCrashKey, default: defaultOfferResumeAfterCrash, defaults: defaults)
    }

    static func injectResumeBreadcrumb(defaults: UserDefaults = .standard) -> Bool {
        boolValue(forKey: injectResumeBreadcrumbKey, default: defaultInjectResumeBreadcrumb, defaults: defaults)
    }

    static func resumeAgentsAfterUpdate(defaults: UserDefaults = .standard) -> Bool {
        boolValue(forKey: resumeAgentsAfterUpdateKey, default: defaultResumeAgentsAfterUpdate, defaults: defaults)
    }

    @MainActor
    static func shouldDeliverSilentReentry(
        launchState: CrashRecoveryLaunchState,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard injectResumeBreadcrumb(defaults: defaults) else { return false }
        if launchState.restoreWasIntended {
            return false
        }
        if launchState.priorRunCrashed {
            return !offerResumeAfterCrash(defaults: defaults)
        }
        return false
    }

    @MainActor
    static func shouldGateRestoredAgentStartup(
        launchState: CrashRecoveryLaunchState,
        defaults: UserDefaults = .standard
    ) -> Bool {
        if launchState.priorRunCrashed {
            return offerResumeAfterCrash(defaults: defaults) ||
                shouldDeliverSilentReentry(launchState: launchState, defaults: defaults)
        }
        if launchState.restoreWasIntended {
            return resumeAgentsAfterUpdate(defaults: defaults)
        }
        return false
    }

    static func setOfferResumeAfterCrash(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: offerResumeAfterCrashKey)
    }

    static func setInjectResumeBreadcrumb(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: injectResumeBreadcrumbKey)
    }

    static func setResumeAgentsAfterUpdate(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: resumeAgentsAfterUpdateKey)
    }

    static func reset(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: offerResumeAfterCrashKey)
        defaults.removeObject(forKey: injectResumeBreadcrumbKey)
        defaults.removeObject(forKey: resumeAgentsAfterUpdateKey)
    }

    private static func boolValue(forKey key: String, default defaultValue: Bool, defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }
}
