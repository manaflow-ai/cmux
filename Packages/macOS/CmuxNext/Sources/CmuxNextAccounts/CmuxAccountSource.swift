/// cmux's own account as Cloud auth exposes it (CmuxNextCloud.CloudAuth;
/// the App declares the conformance). Settings > Accounts reads and drives
/// the same sign-in the palette, the sidebar and the Cloud page use.
@MainActor
public protocol CmuxAccountSource: AnyObject {
    var isSignedIn: Bool { get }
    var accountEmail: String? { get }
    var accountName: String? { get }
    var isSigningIn: Bool { get }
    var signInWaitsInBrowser: Bool { get }
    var signInFailure: String? { get }
    func beginSignIn(selectAccount: Bool) -> Task<Bool, Never>
    func cancelSignIn()
    func continueSignInInBrowser() -> Bool
}

extension CmuxAccountState {
    /// The row's state from `source`: a masked label when signed in, else
    /// where a sign-in in progress stands and why the last one failed.
    @MainActor
    public init(_ source: some CmuxAccountSource) {
        if source.isSignedIn {
            self.init(signedIn: true, label: Self.mask(source.accountEmail) ?? source.accountName)
        } else {
            self.init(signedIn: false, signingIn: source.isSigningIn, waitingForBrowser: source.signInWaitsInBrowser,
                      failure: source.signInFailure)
        }
    }
}

extension CmuxAccountSource {
    /// Runs one gesture of cmux's row. `signOut` is the app's full sign-out;
    /// `refresh` re-reads the screen after a sign-in or a sign-out finishes.
    public func run(_ action: CmuxAccountAction, signOut: @escaping @MainActor () async -> Void,
                    refresh: @escaping @MainActor () -> Void) {
        switch action {
        case .signIn, .switchAccount:
            let attempt = beginSignIn(selectAccount: action == .switchAccount)
            // task-owner: one hosted sign-in; ends when the browser flow returns
            Task { if await attempt.value { refresh() } }
        case .cancelSignIn:
            cancelSignIn()
        case .continueInBrowser:
            _ = continueSignInInBrowser()
        case .signOut:
            // task-owner: one sign-out; the row follows Cloud auth's state
            Task {
                await signOut()
                refresh()
            }
        }
    }
}
