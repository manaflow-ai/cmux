public import CmuxNextCloud
public import CmuxNextCompat
import CmuxNextDesign

extension DeviceHubService {
    /// The hub follows the selected account and keeps preview environments in their own storage namespace.
    public convenience init(pages: MacScreenPages, auth: CloudAuth, configuration: CloudConfiguration,
                            bundleIdentifier: String?, loginKeychain: LoginKeychain) {
        let account = Account(awaitRestored: { await auth.awaitRestored() },
                              userID: { auth.isSignedIn ? (auth.user?.id ?? "") : nil },
                              accessToken: { try await auth.tokens().access },
                              isRestoring: { auth.isRestoring })
        // The home page's and cards' Sign In say what they sign in to (Rust's backend label).
        pages.signInBackend = configuration.backendLabel.map { SignInButton.backendLine(kind: $0.kind, title: $0.title, detail: $0.detail) }
        let selection = configuration.runtimeSelection
        let hubBundle = selection?.storageNamespace.map { "\(selection?.bundleId ?? "cmux").cloud.\($0)" } ?? bundleIdentifier
        self.init(pages: pages, account: account, bundleIdentifier: hubBundle,
                  loginKeychain: loginKeychain, selectedBaseURL: selection?.deviceHubOrigin)
    }
}
