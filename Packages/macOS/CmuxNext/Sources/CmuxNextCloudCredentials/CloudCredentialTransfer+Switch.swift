public import Foundation

extension CloudCredentialTransfer {
    /// The defaults key of ``passesHarnessLogin(isDogfoodBuild:setting:)``.
    public nonisolated static let passHarnessLoginKey = "cmux.cloud.passHarnessLogin"

    /// The one switch for every Mac-to-machine login transfer: `cloud.startChat`'s pass, the turn
    /// card's recovery and the new-workspace setup, Claude's `setup-token` and the Codex broker alike.
    /// DEV and dogfood only (Leo: "IN THE ACTUAL PRODUCTION APP IT MAY BE AGAINST TOS"). The
    /// `cmux.cloud.passHarnessLogin` default wins when set (`-bool NO` makes a DEV build behave as
    /// production); unset, it is on in a dogfood build (the app passes `DevTools.isEnabled`: a Debug
    /// compile or a NIGHTLY bundle, the NEXT nightly included) and off in release, where the machine
    /// signs in on its own instead.
    public nonisolated static func passesHarnessLogin(isDogfoodBuild: Bool, setting: Bool?) -> Bool { setting ?? isDogfoodBuild }

    /// ``passesHarnessLogin(isDogfoodBuild:setting:)`` with the setting read from `defaults`.
    public nonisolated static func passesHarnessLogin(isDogfoodBuild: Bool, defaults: UserDefaults) -> Bool {
        passesHarnessLogin(isDogfoodBuild: isDogfoodBuild, setting: defaults.object(forKey: passHarnessLoginKey) as? Bool)
    }
}
