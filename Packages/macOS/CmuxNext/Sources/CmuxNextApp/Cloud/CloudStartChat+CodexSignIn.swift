import CmuxNextActions
import CmuxNextCloud
import CmuxNextCloudUI
import CmuxNextDesign
import CmuxNextSettings
import Foundation

/// The Mac's own Codex sign-in for the person's own Cloud machines (Leo, 2026-11-05: "claude/codex/
/// antigravity/cursor/muse and those subscriptions should all be detectable / many many existing apps
/// can do this"). Once the person says yes (``CloudCodexSignInConsentSetting``, asked once, only by their
/// click), the Codex broker gives a machine the access token the Mac's Codex already holds
/// (``CloudCodexLocalAccess``) instead of a device-code sign-in. The Mac stays the only refresher.
extension CloudStartChat {
    /// The person's answer in cmux.json; nil when never asked.
    @MainActor static func codexSignInConsent(_ services: AppServices) -> Bool? {
        guard let settings = services.settings else { return nil }
        return CloudCodexSignInConsentSetting().consent(file: settings.fileRoot, effective: settings.snapshot.root,
                                                       managed: settings.managedKey(forPath: CloudCodexSignInConsentSetting.path) != nil)
    }

    /// The Mac's current Codex access, read off the main actor; nil when there is none to offer.
    nonisolated static func macCodexAccess() async -> CloudCodexAccessGrant? {
        let environment = ProcessInfo.processInfo.environment, home = FileManager.default.homeDirectoryForCurrentUser
        return await Task.detached(priority: .userInitiated) {
            CloudCodexLocalAccess.read(home: CloudCodexLocalAccess.home(environment: environment, userHome: home))
        }.value
    }

    /// The broker's ``CloudCodexBrokerAdapter/localSignIn``: the Mac's access only while the person's yes stands.
    @MainActor static func codexLocalSignIn(_ services: AppServices) -> @Sendable () async -> CloudCodexAccessGrant? {
        { [weak services] in
            guard await MainActor.run(body: { services.flatMap(codexSignInConsent) }) == true else { return nil }
            return await macCodexAccess()
        }
    }

    /// The broker's `askLocalSignIn`: true when the person's yes stands (asked once now when never asked,
    /// and only when `mayAsk` and the Mac holds a Codex sign-in to use) and the Mac has access to give.
    @MainActor static func askCodexSignIn(_ services: AppServices, mayAsk: Bool, in scope: CmuxDialogScope?) async -> Bool {
        switch codexSignInConsent(services) {
        case .some(let answer): return answer
        case .none:
            // Never ask about a sign-in the Mac does not have, or where no prompt may show.
            guard mayAsk, let target = scope ?? services.windows.active?.window.map(CmuxDialogScope.window),
                  await macCodexAccess() != nil else { return false }
            let answer = await CmuxDialogCenter.shared.present(CloudCodexSignInConsent.spec, in: target)
            if answer.isDismissal { return false } // no answer kept: asked again next time
            let yes = answer.button == CloudCodexSignInConsent.accept
            try? await services.settings?.setSetting(at: CloudCodexSignInConsentSetting.path, to: .bool(yes), by: .user)
            return yes
        }
    }
}
