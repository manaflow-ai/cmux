import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextMobileHost
import CmuxNextSettings
import Foundation

/// Session Info's Remote Control switch (``AgentPaneRemoteControl``) on the App's side: it is the
/// iPhone host's own switch, `mobile.allowIPhoneConnections`, the one the Mobile Pairing page and
/// Settings > Mobile show, so cmux on the same account's iPhone can open this Mac's chats. It is
/// shown while this Mac can serve phones (an account signed in, a build that bundles hostd).
extension AgentTabStore {
    static func wireRemoteControl(_ services: AppServices) {
        let control = AgentPaneRemoteControl.shared
        // The person's own change, as the Mobile Pairing page writes it (agent policy `userOnly`).
        control.set = { [weak services] on in
            guard let settings = services?.settings else { throw CocoaError(.featureUnsupported) }
            try await settings.setSetting(at: MobileSettings.allowIPhoneConnectionsPath, to: .bool(on), by: .user)
        }
        // Set last: setting it pushes the state to the open pages.
        control.state = { [weak services] in
            guard let services, let settings = services.settings else { return nil }
            return remoteControlState(signedIn: services.cloud.isSignedIn, servesPhones: services.iphone.servesPhones,
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
