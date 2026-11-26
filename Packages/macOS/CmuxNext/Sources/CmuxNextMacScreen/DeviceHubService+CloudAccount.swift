public import CmuxNextCloud
public import CmuxNextCompat
import CmuxNextDevices

extension DeviceHubService {
    /// The hub follows the selected account and keeps preview environments in their own storage namespace.
    public convenience init(pages: MacScreenPages, auth: CloudAuth, configuration: CloudConfiguration,
                            bundleIdentifier: String?, loginKeychain: LoginKeychain) {
        let account = Account(awaitRestored: { await auth.awaitRestored() },
                              userID: { auth.isSignedIn ? (auth.user?.id ?? "") : nil },
                              accessToken: { try await auth.tokens().access },
                              isRestoring: { auth.isRestoring })
        let selection = configuration.runtimeSelection
        let hubBundle = selection?.storageNamespace.map { "\(selection?.bundleId ?? "cmux").cloud.\($0)" } ?? bundleIdentifier
        self.init(pages: pages, account: account, bundleIdentifier: hubBundle,
                  loginKeychain: loginKeychain, selectedBaseURL: selection?.deviceHubOrigin,
                  buildSpace: Self.hubBuildSpace(configuration))
    }

    /// The hub's build space: the build's cloud data space (``CloudConfiguration/buildSpace``), so a tagged dev
    /// build's Mac is a device of its tag's space on the hub as it is everywhere else. A DEV build with no usable
    /// tag makes no hub calls rather than join NIGHTLY's devices.
    nonisolated static func hubBuildSpace(_ configuration: CloudConfiguration) -> DeviceHubBuildSpace {
        let state = configuration.buildSpace
        if state.refusal != nil { return .unusable }
        guard let space = state.space else { return .nightly }
        return .dev(space.headerValue)
    }
}
