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

    /// The team's CodeRouter accounts this user may see.
    func linkedAccounts() async throws -> [LinkedAccount]
    /// Builds the credential (from the local sign-in, the environment, the
    /// cmux Keychain, or `pasted`) and adds it to CodeRouter.
    func connect(_ provider: AIProvider, pasted: String?) async throws
    func remove(_ account: LinkedAccount) async throws

    /// Runs the provider's own login: its CLI in a new cmux terminal tab,
    /// or its page in a cmux browser tab. Returns when the tab is open; the
    /// screen re-detects when the app becomes active again.
    func reauthenticate(_ provider: AIProvider, plan: ReauthPlan)
    /// Runs `claude setup-token` in a terminal tab, so the user can copy the
    /// token into the paste field.
    func runClaudeSetupToken()
    /// Opens the provider's key page in a browser tab.
    func openConsole(_ url: URL)

    /// Saves a pasted key to cmux's Keychain item (never cmux.json).
    func saveKey(_ key: String, for provider: AIProvider) throws
    func deleteSavedKey(for provider: AIProvider) throws
}
