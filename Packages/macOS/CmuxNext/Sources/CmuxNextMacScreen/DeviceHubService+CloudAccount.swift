public import CmuxNextCloud
public import CmuxNextCompat

extension DeviceHubService {
    /// The hub follows the selected account and keeps preview environments in their own storage namespace.
    public convenience init(pages: MacScreenPages, auth: CloudAuth, configuration: CloudConfiguration,
                            bundleIdentifier: String?, loginKeychain: LoginKeychain) {
        let account = Account(awaitRestored: { await auth.awaitRestored() },
                              userID: { auth.isSignedIn ? (auth.user?.id ?? "") : nil },
                              accessToken: { try await auth.tokens().access })
        let selection = configuration.runtimeSelection
        let hubBundle = selection?.storageNamespace.map { "\(selection?.bundleId ?? "cmux").cloud.\($0)" } ?? bundleIdentifier
        self.init(pages: pages, account: account, bundleIdentifier: hubBundle,
                  loginKeychain: loginKeychain, selectedBaseURL: selection?.deviceHubOrigin)
    }
}
