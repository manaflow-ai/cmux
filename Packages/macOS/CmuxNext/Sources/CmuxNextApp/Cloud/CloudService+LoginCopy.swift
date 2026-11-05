import CmuxNextActions
import CmuxNextCloud
import CmuxNextCloudCredentials
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
                                                     managed: settings.managedKey(forPath: CloudLoginCopyConsentSetting.path) != nil)
    }

    /// Asks the one-time consent and keeps the answer as the person's (yes or no; no window shown
    /// keeps nothing, so it is asked next time). Answers whether they said yes.
    @MainActor static func askLoginCopyConsent(_ services: AppServices) async -> Bool {
        guard let answer = await CloudPresenter.confirmLoginCopy(services: services) else { return false }
        try? await services.settings?.setSetting(at: CloudLoginCopyConsentSetting.path, to: .bool(answer), by: .user)
        return answer
    }

    /// The Release copy's gate (``CloudLoginCopyGate``) over this app's switch, cmux.json and consent dialog.
    @MainActor static func loginCopyGate(_ services: AppServices) -> CloudLoginCopyGate {
        CloudLoginCopyGate(dogfood: DevTools.isEnabled, readSwitch: { [weak services] in await services?.cloud.readHarnessLoginCopySwitch() },
                           consent: { [weak services] in services.flatMap(loginCopyConsent) },
                           ask: { [weak services] in
                               guard let services else { return false }
                               return await askLoginCopyConsent(services)
                           })
    }
}
