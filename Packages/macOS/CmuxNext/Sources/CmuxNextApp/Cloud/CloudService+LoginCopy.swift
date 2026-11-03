import CmuxNextActions
import CmuxNextCloud
import CmuxNextCloudCredentials
import CmuxNextSettings
import Foundation

/// The Release copy of the person's own Claude login to their own Cloud machine (Leo, 2026-11-02),
/// on his three conditions:
///
/// 1. "Consent first. It's on only after a clear one-time prompt: 'use my Claude login on my own
///    Cloud machines'." The answer is kept in cmux.json (``CloudLoginCopyConsentSetting``), which
///    only the person sets and Settings > Machines takes back.
/// 2. "Your token only: your own token, to your own machine. Never stored by us, never on team
///    machines, never shared." Only where the platform says the caller owns the machine and its
///    guest is an `owner` one (cmux-cloud-start-core; never a team guest in Release), written from
///    this Mac to the machine's disk over the machine routes, which keep and log none of it.
/// 3. "A remote off switch": ``CloudHarnessLoginCopySwitch``, read before each copy. Off, the copy
///    is skipped and the machine's chat offers the one-click "Sign in to Claude".
///
/// DEV and NIGHTLY builds keep their dogfood gate: none of this is read there.
extension CloudService {
    /// Reads the remote switch now (5 s at most) and answers it: nil (off) on any failure.
    func readHarnessLoginCopySwitch() async -> Bool? {
        let auth = auth, identity = installIdentity
        let owner = CloudOwnerAPIClient(baseURL: FeedService.apiBaseURL(auth: auth), accessToken: { try await auth.tokens().access },
                                        teamID: { (try? await identity.installToken()).flatMap(MacInstallIdentity.team(ofToken:)) })
        return await harnessLoginCopySwitch.read(owner)
    }
}

extension CloudStartChat {
    /// The person's answer to the one-time consent in cmux.json; nil when never asked.
    @MainActor static func loginCopyConsent(_ services: AppServices) -> Bool? {
        CloudLoginCopyConsentSetting().consent(in: services.settings?.snapshot.root ?? .object([:]))
    }

    /// Asks the one-time consent and keeps the answer as the person's (yes or no; no window shown
    /// keeps nothing, so it is asked next time). Answers whether they said yes.
    @MainActor static func askLoginCopyConsent(_ services: AppServices) async -> Bool {
        guard let answer = await CloudPresenter.confirmLoginCopy(services: services) else { return false }
        try? await services.settings?.setSetting(at: CloudLoginCopyConsentSetting.path, to: .bool(answer), by: .user)
        return answer
    }

    /// Whether a Release turn card may copy the login now (its recovery): the switch read fresh,
    /// then the person's consent, asked once. DEV and NIGHTLY builds answer true (their own gate).
    @MainActor static func releaseCopyAllowed(_ services: AppServices) async -> Bool {
        guard !DevTools.isEnabled else { return true }
        guard await services.cloud.readHarnessLoginCopySwitch() == true else { return false }
        if let consent = loginCopyConsent(services) { return consent }
        return await askLoginCopyConsent(services)
    }
}
