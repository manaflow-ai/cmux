import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextSettings
import Foundation

/// Session Info's Remote Control switch (``AgentPaneRemoteControl``) on the iPhone host's side: it
/// is this host's own switch, `mobile.allowIPhoneConnections`, the one the Mobile Pairing page and
/// Settings > Mobile show, so cmux on the same account's iPhone can open this Mac's chats. It is
/// shown while this Mac can serve phones (an account signed in, a build that bundles hostd).
extension IPhoneHostService {
    /// Wires ``remoteControl`` to `auth`'s sign-in and the settings `wire` follows (called by `wire`).
    func wireRemoteControl(auth: CloudAuth, settings: @escaping @MainActor @Sendable () -> SettingsController?) {
        let control = remoteControl
        // The person's own change, as the Mobile Pairing page writes it (agent policy `userOnly`).
        control.set = { on in
            guard let settings = settings() else { throw CocoaError(.featureUnsupported) }
            try await settings.setSetting(at: MobileSettings.allowIPhoneConnectionsPath, to: .bool(on), by: .user)
        }
        // A chat row changes only its own durable Rust-owned exposure entry. A page without a
        // session retains the legacy account-wide switch for new-tab/old-host compatibility.
        control.setForSession = { [weak self] on, sessionID in
            guard let self else { throw CocoaError(.featureUnsupported) }
            if let sessionID, !sessionID.isEmpty {
                try await self.supervisor.setSessionExposure(sessionID: sessionID, allowed: on)
            } else {
                guard let settings = settings() else { throw CocoaError(.featureUnsupported) }
                try await settings.setSetting(at: MobileSettings.allowIPhoneConnectionsPath, to: .bool(on), by: .user)
            }
        }
        control.sessionState = { [weak self] sessionID in
            guard let self, let settings = settings() else { return nil }
            return Self.remoteControlState(signedIn: auth.isSignedIn, servesPhones: servesPhones,
                                           allowed: settings.snapshot.mobile.allowIPhoneConnections,
                                           sessionID: sessionID, exposureConfigured: sessionExposureConfigured,
                                           exposedSessionIDs: exposedSessionIDs,
                                           blockedSessionIDs: blockedSessionIDs,
                                           exposureAvailable: sessionExposureAvailable,
                                           exposureKnown: sessionExposureKnown,
                                           revision: sessionExposureRevision)
        }
        // Set last: setting it pushes the state to the open pages.
        control.state = { [weak self] in
            guard let self, let settings = settings() else { return nil }
            return Self.remoteControlState(signedIn: auth.isSignedIn, servesPhones: servesPhones,
                                           allowed: settings.snapshot.mobile.allowIPhoneConnections,
                                           sessionID: nil, exposureConfigured: sessionExposureConfigured,
                                           exposedSessionIDs: exposedSessionIDs,
                                           blockedSessionIDs: blockedSessionIDs,
                                           exposureAvailable: sessionExposureAvailable,
                                           exposureKnown: sessionExposureKnown,
                                           revision: sessionExposureRevision)
        }
    }

    /// The switch Session Info shows: none while no account is signed in (phones have no account to
    /// match) or the build has no iPhone host; otherwise on as the setting is.
    nonisolated static func remoteControlState(signedIn: Bool, servesPhones: Bool, allowed: Bool,
                                               sessionID: String? = nil, exposureConfigured: Bool = false,
                                               exposedSessionIDs: Set<String> = [], blockedSessionIDs: Set<String> = [],
                                               exposureAvailable: Bool = true,
                                               exposureKnown: Bool = true,
                                               revision: Int = 0) -> AgentPaneRemoteControl.State? {
        guard signedIn, servesPhones else { return nil }
        let on: Bool
        if !allowed {
            on = false
        } else if let sessionID {
            on = exposureKnown && exposureAvailable
                ? (exposureConfigured ? !blockedSessionIDs.contains(sessionID) : allowed)
                : false
        } else {
            // New-tab/legacy callers retain master fallback because they have no session to
            // authorize; a concrete chat above fails closed until host state is authoritative.
            on = allowed
        }
        return AgentPaneRemoteControl.State(on: on, revision: revision)
    }
}
