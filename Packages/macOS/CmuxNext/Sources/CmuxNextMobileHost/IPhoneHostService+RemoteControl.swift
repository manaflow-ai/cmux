import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextSettings
import Foundation

/// Session Info's Remote Control switch (``AgentPaneRemoteControl``) on the iPhone host's side: it
/// is this host's own switch, `mobile.allowIPhoneConnections`, the one Settings > Accounts > iPhone and
/// Settings > Mobile show, so cmux on the same account's iPhone can open this Mac's chats. It is
/// app-wide, all or nothing: every chat's row shows and writes this one switch, and no chat has
/// an exposure of its own. It is shown while this Mac can serve phones (an account signed in, a
/// build that bundles hostd).
extension IPhoneHostService {
    /// Wires ``remoteControl`` to `auth`'s sign-in and the settings `wire` follows (called by `wire`).
    func wireRemoteControl(auth: CloudAuth, settings: @escaping @MainActor @Sendable () -> SettingsController?) {
        let control = remoteControl
        // The person's own change, as Settings > Accounts > iPhone writes it (agent policy `userOnly`),
        // from whichever chat's row it came.
        control.set = { on in
            guard let settings = settings() else { throw CocoaError(.featureUnsupported) }
            try await settings.setSetting(at: MobileSettings.allowIPhoneConnectionsPath, to: .bool(on), by: .user)
        }
        // Set last: setting it pushes the state to the open pages.
        control.state = { [weak self] in
            guard let self, let settings = settings() else { return nil }
            return Self.remoteControlState(signedIn: auth.isSignedIn, servesPhones: servesPhones,
                                           allowed: settings.snapshot.mobile.allowIPhoneConnections)
        }
    }

    /// The switch Session Info shows: none while no account is signed in (phones have no account to
    /// match) or the build has no iPhone host; otherwise on as the setting is.
    nonisolated static func remoteControlState(signedIn: Bool, servesPhones: Bool, allowed: Bool) -> AgentPaneRemoteControl.State? {
        guard signedIn, servesPhones else { return nil }
        return AgentPaneRemoteControl.State(on: allowed)
    }
}
