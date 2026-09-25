#if os(iOS)
import CmuxMobileShell
import CmuxMobileSupport
import Foundation
import Observation
import SwiftUI

/// Where a signed-out launch lands (PRD D5): the SSH shell or sign-in.
///
/// `nil` (the default) means automatic: the SSH shell when this iPhone has
/// saved SSH computers, sign-in otherwise. Choosing "Connect with SSH" on the
/// sign-in screen pins the SSH shell; choosing "Sign In" from the SSH shell
/// pins sign-in. Signing in resets to automatic, so a later sign-out with saved
/// SSH computers keeps them one tap away. Persisted across launches.
@MainActor
@Observable
final class MobileSSHOnlyPreference {
    static let storageKey = "cmux.ssh.signedOutShellChoice"

    @ObservationIgnored private let defaults: UserDefaults
    private(set) var choice: Bool?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        choice = defaults.object(forKey: Self.storageKey) as? Bool
    }

    /// Whether a signed-out root shows the SSH shell instead of sign-in.
    func showsSignedOutShell(hasSSHComputers: Bool) -> Bool {
        choice ?? hasSSHComputers
    }

    /// The user chose SSH without an account.
    func chooseSSHShell() { set(true) }

    /// The user asked to sign in from the SSH shell.
    func chooseSignIn() { set(false) }

    /// A successful sign-in returns to automatic.
    func reset() { set(nil) }

    private func set(_ value: Bool?) {
        guard choice != value else { return }
        choice = value
        if let value {
            defaults.set(value, forKey: Self.storageKey)
        } else {
            defaults.removeObject(forKey: Self.storageKey)
        }
    }
}

private struct MobileSSHOnlyEntryKey: EnvironmentKey {
    static let defaultValue: (@MainActor () -> Void)? = nil
}

extension EnvironmentValues {
    /// Enters the signed-out SSH shell. `nil` hides the sign-in entrypoint.
    var mobileSSHOnlyEntry: (@MainActor () -> Void)? {
        get { self[MobileSSHOnlyEntryKey.self] }
        set { self[MobileSSHOnlyEntryKey.self] = newValue }
    }
}

/// Signed out with no SSH computers yet: the one thing to do is add one.
/// No Mac pairing prompts here; "Sign In" returns to the account screen.
struct SSHOnlyWelcomeView: View {
    let computers: MobileSSHComputers
    let addComputer: () -> Void
    let signIn: () -> Void

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label(
                    L10n.string("mobile.ssh.welcome.title", defaultValue: "Connect with SSH"),
                    systemImage: "terminal"
                )
            } description: {
                Text(L10n.string(
                    "mobile.ssh.welcome.message",
                    defaultValue: "Open a terminal on any computer running an SSH server. No cmux account needed, and computers you add stay on this iPhone."
                ))
            } actions: {
                Button(action: addComputer) {
                    Text(SSHCopy().addComputer)
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("ssh.addComputer")
                NavigationLink {
                    SSHKeysView(computers: computers)
                } label: {
                    Text(SSHCopy().keysTitle)
                }
                .accessibilityIdentifier("ssh.welcome.keys")
            }
            .navigationTitle(L10n.string("mobile.workspaces.title", defaultValue: "Workspaces"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(
                        L10n.string("mobile.ssh.welcome.signIn", defaultValue: "Sign In"),
                        action: signIn
                    )
                    .accessibilityIdentifier("ssh.welcome.signIn")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: addComputer) {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(SSHCopy().addComputer)
                    .accessibilityIdentifier("ssh.welcome.add")
                }
            }
        }
        .accessibilityIdentifier("ssh.welcome")
    }
}
#endif
