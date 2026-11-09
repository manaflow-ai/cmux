import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextCloudCredentials
import CmuxNextCloudUI
import CmuxNextDesign
import CmuxNextSettings
import Foundation

/// The Release copy of the person's Claude login: the rules are ``CloudLoginCopyGate``'s; this reads the app's parts.
extension CloudService {
    /// Reads the remote switch now (5 s at most) and answers it: nil (off) on any failure.
    @discardableResult func readHarnessLoginCopySwitch() async -> Bool? {
        let auth = auth, identity = installIdentity
        let owner = CloudOwnerAPIClient(baseURL: FeedService.apiBaseURL(auth: auth), accessToken: { try await auth.tokens().access },
                                        teamID: { (try? await identity.installToken()).flatMap(MacInstallIdentity.team(ofToken:)) })
        return await harnessLoginCopySwitch.read(owner)
    }
}

extension CloudStartChat {
    /// The person's answer to the one-time consent in cmux.json; nil when never asked.
    @MainActor static func loginCopyConsent(_ services: AppServices) -> Bool? {
        guard let settings = services.settings else { return nil }
        return CloudLoginCopyConsentSetting().consent(file: settings.fileRoot, effective: settings.snapshot.root,
                                                     managed: settings.managedKey(forPath: CloudLoginCopyConsentSetting.configPath) != nil)
    }

    /// Asks the one-time consent through `asker` and keeps the answer as the person's (yes or no; a
    /// question left unanswered keeps nothing, so it is asked next time). Answers whether they said yes.
    @MainActor static func askLoginCopyConsent(_ services: AppServices, asker: AgentPaneCloudAsker) async -> Bool {
        guard let yes = await asker.ask(AgentPaneCloudAsk(kind: .loginCopy, spec: CloudLoginCopyConsent.spec)).map({ $0 == CloudLoginCopyConsent.accept }) else { return false }
        try? await services.settings?.setSetting(at: CloudLoginCopyConsentSetting.configPath, to: .bool(yes), by: .user)
        return yes
    }

    /// Warms the person's spare and copies their login onto it (``CloudSpareWarm``), never awaited by the caller.
    @MainActor static func warmSpare(_ services: AppServices, claimed: String? = nil) {
        let cloud = services.cloud
        guard !services.registry.disabledFeatures.contains(.cloud), cloud.mayCallCloud, let binary = cloud.move.cli, let platform = cloud.configuration.artifactsAPIBaseURL() else { return }
        CloudSpareWarm(auth: cloud.auth, cli: CloudMoveCLI(binary: binary), platform: platform, api: cloud.machineAPI, installIdentity: cloud.installIdentity,
                       gate: loginCopyGate(services), dogfood: DevTools.isEnabled, logger: cloud.logger).start(claimed: claimed)
    }

    /// The Release copy's gate (``CloudLoginCopyGate``) over this app's switch, cmux.json and consent,
    /// asked by `asker` (a start's card), else as a dialog in the active window.
    @MainActor static func loginCopyGate(_ services: AppServices, asker: AgentPaneCloudAsker? = nil) -> CloudLoginCopyGate {
        CloudLoginCopyGate(dogfood: DevTools.isEnabled, readSwitch: { [weak services] in await services?.cloud.readHarnessLoginCopySwitch() },
                           consent: { [weak services] in services.flatMap(loginCopyConsent) },
                           ask: { [weak services] in
                               guard let services else { return false }
                               return await askLoginCopyConsent(services, asker: asker ?? .window(services))
                           })
    }
}

extension AgentPaneCloudAsker {
    /// As a dialog on the active window of `services` when the question shows (no card to ask in).
    @MainActor static func window(_ services: AppServices) -> AgentPaneCloudAsker {
        dialog({ [weak services] in services?.windows.active?.window.map(CmuxDialogScope.window) })
    }
}
