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
    /// DEV and dogfood only (Leo: "IN THE ACTUAL PRODUCTION APP IT MAY BE AGAINST TOS"): on in a
    /// dogfood build (the app passes `DevTools.isEnabled`: a Debug compile or a NIGHTLY bundle, the
    /// NEXT nightly included) unless `cmux.cloud.passHarnessLogin` is `NO`, and always off in
    /// release, whatever the default says, where the machine signs in on its own instead. The precedence is Rust's (cmux-cloud-start-core
    /// `passes_harness_login`); an FFI that does not answer passes no login.
    public nonisolated static func passesHarnessLogin(isDogfoodBuild: Bool, defaults: UserDefaults) -> Bool {
        CloudHarnessLoginDecision(dogfood: isDogfoodBuild, setting: passHarnessLoginSetting(defaults), harness: nil, signedIn: false).gate
    }
}
