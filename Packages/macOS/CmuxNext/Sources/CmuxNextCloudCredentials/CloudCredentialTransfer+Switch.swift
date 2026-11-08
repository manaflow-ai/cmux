public import Foundation

extension CloudCredentialTransfer {
    /// The defaults key of ``passesHarnessLogin(isDogfoodBuild:defaults:)``.
    public nonisolated static let passHarnessLoginKey = "cmux.cloud.passHarnessLogin"

    /// The `cmux.cloud.passHarnessLogin` setting in `defaults`; nil when unset.
    public nonisolated static func passHarnessLoginSetting(_ defaults: UserDefaults) -> Bool? {
        defaults.object(forKey: passHarnessLoginKey) as? Bool
    }

    /// The one switch for every Mac-to-machine login transfer: `cloud.startChat`'s pass, the turn
    /// card's recovery and the new-workspace setup, Claude's `setup-token` and the Codex broker alike.
    /// On in a dogfood build (the app passes `DevTools.isEnabled`: a Debug compile or a NIGHTLY
    /// bundle, the NEXT nightly included) unless `cmux.cloud.passHarnessLogin` is NO. In Release
    /// (Leo, 2026-11-02, on three conditions: consent first, your own token to your own machine
    /// only, and a remote off switch) only while `remoteSwitch` (the API Worker's
    /// ``CloudHarnessLoginCopySwitch``) is on; the person's one-time consent is asked where a copy
    /// would happen. The rules are Rust's (cmux-cloud-start-core `passes_harness_login` and
    /// `release_passes_harness_login`); an FFI that does not answer passes no login.
    public nonisolated static func passesHarnessLogin(isDogfoodBuild: Bool, defaults: UserDefaults, remoteSwitch: Bool? = nil) -> Bool {
        var decision = CloudHarnessLoginDecision(dogfood: isDogfoodBuild, setting: passHarnessLoginSetting(defaults), harness: nil, signedIn: false)
        decision.remoteSwitch = remoteSwitch
        return decision.gate
    }

    /// Whether this build may offer the copy at all (the turn card's recovery): a dogfood build by its
    /// gate; Release unless `cmux.cloud.passHarnessLogin` is NO, the switch and the consent being
    /// checked when it runs (``CloudLoginCopyGate``).
    public nonisolated static func offersLoginCopy(isDogfoodBuild: Bool, defaults: UserDefaults) -> Bool {
        isDogfoodBuild ? passesHarnessLogin(isDogfoodBuild: true, defaults: defaults) : passHarnessLoginSetting(defaults) != false
    }

    /// Whether a team guest whose creator is the caller may take the login: a dogfood build only.
    /// A Release copy goes only to an `owner` guest ("never on team machines").
    public nonisolated static func allowsCreatorTeamGuest(isDogfoodBuild: Bool, defaults: UserDefaults) -> Bool {
        isDogfoodBuild && passesHarnessLogin(isDogfoodBuild: true, defaults: defaults)
    }
}
