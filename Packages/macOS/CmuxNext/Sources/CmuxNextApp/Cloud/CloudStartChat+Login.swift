import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextCloudCredentials
import Foundation

/// A `cloud.startChat` chat's harness login, before its first prompt (Leo, 2026-10-31: "A TOKEN GETS
/// PASSED"). On a machine the signed-in person owns (the attach answer's `vmKind == "owner"`, which a
/// team machine's creator gets too, #28788), Claude gets the person's own `claude setup-token`
/// login through ``CloudCredentialTransfer``: silently when cmux already holds that login for this
/// account, else after one confirm that runs `setup-token` once in a visible local terminal. Every
/// later machine of the account then gets it with no prompt.
///
/// DEV and dogfood builds pass it as before. A Release build passes it only on Leo's three
/// conditions (2026-11-02; CloudService+LoginCopy.swift): the remote switch on, the person's
/// one-time consent ("Use my Claude login on my own Cloud machines?", which is the confirm, so no
/// second prompt follows), and an `owner` guest of a machine the caller owns, never a team one.
/// Otherwise the machine's chat offers its own one-click "Sign in to Claude".
///
/// The decision's rules are Rust's (``CloudHarnessLoginDecision``, cmux-cloud-start-core); this
/// extension reads the machine and the account and acts on it.
///
/// Never blocks the chat: a machine that is not the person's, a cancelled confirm or a failed install
/// opens the chat anyway, and its turn card still offers recovery (#26148).
extension CloudStartChat {
    /// This process's answer to ``CloudCredentialTransfer/passesHarnessLogin(isDogfoodBuild:defaults:remoteSwitch:)``,
    /// with a Release build's last fresh switch answer (`switch`): what the turn card and the
    /// workspace setup offer. The copy itself reads the switch again first.
    nonisolated static func passesHarnessLoginHere(switch remoteSwitch: CloudHarnessLoginCopySwitch?) -> Bool {
        CloudCredentialTransfer.passesHarnessLogin(isDogfoodBuild: DevTools.isEnabled, defaults: .standard, remoteSwitch: remoteSwitch?.current)
    }

    /// Whether this build may offer the copy at all (the turn card's recovery): DEV and dogfood by
    /// their gate; Release unless `cmux.cloud.passHarnessLogin` is NO, the switch and the consent
    /// being checked when it runs.
    nonisolated static var offersLoginCopyHere: Bool {
        DevTools.isEnabled ? passesHarnessLoginHere(switch: nil) : CloudCredentialTransfer.passHarnessLoginSetting(.standard) != false
    }

    /// Whether a team guest whose creator is the caller may take the login: DEV and dogfood only.
    /// A Release copy goes only to an `owner` guest ("never on team machines").
    nonisolated static var allowsCreatorTeamGuestHere: Bool {
        DevTools.isEnabled && passesHarnessLoginHere(switch: nil)
    }

    /// Gives the start's machine the person's Claude login when this build passes it. Returns
    /// whether a login was installed; never throws. `cmux cloud start-session` passes it the same way.
    func passHarnessLogin(harness: String?, machine: CloudMachineSession) async -> Bool {
        let cloud = services.cloud, userID = cloud.auth.user?.id
        let teamID = cloud.auth.teamID, machineID = machine.machineID
        let api = cloud.machineAPI.pinningTeam(teamID)
        var decision = CloudHarnessLoginDecision(dogfood: DevTools.isEnabled, setting: CloudCredentialTransfer.passHarnessLoginSetting(.standard),
                                                 harness: harness, signedIn: userID != nil)
        if !DevTools.isEnabled {
            // Release: the switch is read fresh for every start, so turning it off holds the next machine.
            decision.remoteSwitch = await cloud.readHarnessLoginCopySwitch()
            decision.consent = Self.loginCopyConsent(services)
        }
        // Never silent (CloudHarnessLoginDecision): the reason goes to the log and the machine's `cloud.machines` row.
        defer {
            machine.harnessLogin = decision
            cloud.logger.info("cloud start chat: harness login \(decision.summary, privacy: .public)")
        }
        do {
            var verdict = decision.verdict // One FFI answer per step (cmux#32483): a step's fields never mix a failed call with a good one.
            if verdict.gate, verdict.transferProvider == .claude, let userID {
                decision.callerOwns = try await cloud.callerOwnsVM(machineID)
                verdict = decision.verdict
                if verdict.readsMachine { decision.guestStdout = (try? await api.exec(machineID, command: verdict.guestKindProbe, timeoutMs: 20_000))?.stdout }
                // A login the provider rejects (a reused machine's expired token) is replaced like a missing one.
                if decision.verdict.guestTakesLogin { decision.take(await CloudMachineLogin.read(on: api, machineID: machineID, teamID: teamID, userID: userID)) }
            }
            verdict = decision.verdict
            guard let provider = verdict.transferProvider, let userID else { return false }
            switch verdict.step {
            case .skip: return false
            case .install: break
            case .askConsent:
                // The one-time consent is the confirm: yes copies now, with no second prompt.
                guard await Self.askLoginCopyConsent(services) else {
                    decision.consent = Self.loginCopyConsent(services)
                    decision.outcome = "declined"
                    return false
                }
                decision.consent = true
                guard decision.verdict.step == .install else { return false }
            case .confirmThenInstall:
                guard await CloudPresenter.confirmFirstLogin(provider: provider, machine: machine.machine.title, services: services) else {
                    decision.outcome = "declined"
                    return false
                }
            }
            guard cloud.auth.user?.id == userID, cloud.auth.teamID == teamID else { return false }
            let transfer = CloudCredentialTransfer(provider: provider, machineID: machineID, teamID: teamID, userID: userID,
                allowsCreatorTeamGuest: verdict.guestKind == "team" && Self.allowsCreatorTeamGuestHere, openTerminal: { [weak services] line in await services?.openLocalProviderLogin(line) ?? false })
            try await transfer.run(api: cloud.machineAPI, currentTeamID: { cloud.auth.teamID }, currentUserID: { cloud.auth.user?.id },
                                   confirmed: true, callerOwnsVM: { try await cloud.callerOwnsVM(machineID) },
                                   stillAllowed: Self.releaseStillAllowed(services))
            decision.outcome = "installed"
            return true
        } catch {
            // The message is the transfer's fixed text, never provider output.
            decision.outcome = "failed: " + ((error as? LocalizedError)?.errorDescription ?? String(describing: type(of: error)))
            return false
        }
    }
}
