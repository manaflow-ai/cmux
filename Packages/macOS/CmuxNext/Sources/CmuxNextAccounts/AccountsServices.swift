public import CMUXAuthCore
public import CmuxNextCloud
public import CmuxNextCodeRouter
public import Foundation

/// What the Accounts screen needs from the App. The App implements it over
/// the login-shell environment, the Keychain, Cloud sign-in, the CodeRouter
/// client and its terminal and browser tabs; ``MockAccountsServices`` runs
/// the screen alone (demo, tests).
@MainActor
public protocol AccountsServices: AnyObject {
    /// Detects every provider off the main actor (presence only).
    func detect() async -> [ProviderDetection]

    /// Whether cmux is signed in; CodeRouter acts as that user and team.
    var isSignedInToCmux: Bool { get }
    /// Starts the hosted cmux sign-in.
    func signInToCmux()
    /// cmux's account and the sign-in in progress; observable reads.
    var cmuxAccount: CmuxAccountState { get }
    /// Runs one gesture of cmux's row (sign in, cancel, open in the browser,
    /// switch account, sign out).
    func runCmuxAccount(_ action: CmuxAccountAction)

    /// The team cmux works in while signed in (nil when signed out): the
    /// screen lists its teams and switches through it.
    var activeTeam: ActiveTeam? { get }

    /// Team roles, details, create, rename and delete (nil: none here).
    var teamBackend: (any AccountsTeamBackend)? { get }

    /// The team's CodeRouter accounts this user may see.
    func linkedAccounts() async throws -> [LinkedAccount]
    /// Builds the credential (from the local sign-in, the environment, the
    /// cmux Keychain, or `pasted`) and adds it to CodeRouter.
    func connect(_ provider: AIProvider, pasted: String?) async throws
    func remove(_ account: LinkedAccount) async throws

    /// Runs the provider's own login: its CLI in a new cmux terminal tab,
    /// or its page in a cmux browser tab. Returns when the tab is open; the
    /// screen re-detects when the app becomes active again. False when
    /// nothing opened: no window with a pane on this Mac to open it in.
    @discardableResult
    func reauthenticate(_ provider: AIProvider, plan: ReauthPlan) -> Bool
    /// Runs `claude setup-token` in a terminal tab, so the user can copy the
    /// token into the paste field.
    func runClaudeSetupToken()
    /// Opens the provider's key page in a browser tab.
    func openConsole(_ url: URL)

    /// Saves a pasted key to cmux's Keychain item (never cmux.json).
    func saveKey(_ key: String, for provider: AIProvider) throws
    func deleteSavedKey(for provider: AIProvider) throws
}

/// Team management for the Accounts screen: `CloudAuth` in the app (through
/// the auth coordinator, so the team list, the active team and everything that
/// follows it change together), ``MockAccountsServices`` in the demo and tests.
/// Failures are `CMUXTeamError`.
@MainActor
public protocol AccountsTeamBackend: AnyObject {
    /// The account's teams with the person's role in each (roles nil when
    /// only the sign-in service answered).
    func teamMemberships() async throws -> CMUXTeamMemberships
    /// One team's members, pending invitations and plan.
    func teamDetail(id: String) async throws -> CMUXTeamDetail
    /// Creates a team (the person becomes its admin) and makes it the active team.
    func createTeam(named name: String) async throws -> CMUXAuthTeam
    /// Renames a team (admins only).
    func renameTeam(id: String, to name: String) async throws
    /// Deletes a team (admins only). When it was the active team, another becomes active.
    func deleteTeam(id: String) async throws
}

extension CloudAuth: AccountsTeamBackend {}

extension AccountsServices {
    public var isSignedInToCmux: Bool { cmuxAccount.signedIn }
    public func signInToCmux() { runCmuxAccount(.signIn) }
}
