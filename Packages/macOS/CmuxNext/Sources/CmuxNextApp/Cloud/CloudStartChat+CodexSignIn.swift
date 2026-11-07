import CmuxNextActions
import CmuxNextAgentPane
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
            CloudCodexLocalAccess(home: CloudCodexLocalAccess.home(environment: environment, userHome: home)).read()
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
    /// As a dialog in `scope` (nil: the active window), for work with no start card (Sign In to Codex, a chat's recovery).
    @MainActor static func askCodexSignIn(_ services: AppServices, mayAsk: Bool, in scope: CmuxDialogScope?) async -> Bool {
        await askCodexSignIn(services, mayAsk: mayAsk, asker: scope.map { scope in .dialog({ scope }) } ?? .window(services))
    }

    /// The same, asked by `asker` (a composer start's card).
    @MainActor static func askCodexSignIn(_ services: AppServices, mayAsk: Bool, asker: AgentPaneCloudAsker) async -> Bool {
        switch codexSignInConsent(services) {
        case .some(let answer): return answer
        case .none:
            // Never ask about a sign-in the Mac does not have, or where no prompt may show.
            guard mayAsk, await macCodexAccess() != nil else { return false }
            // No answer (dismissed, no window, the start ended): nothing kept, asked again next time.
            guard let answer = await asker.ask(AgentPaneCloudAsk(kind: .codexConsent, spec: CloudCodexSignInConsent.spec)) else { return false }
            let yes = answer == CloudCodexSignInConsent.accept
            try? await services.settings?.setSetting(at: CloudCodexSignInConsentSetting.path, to: .bool(yes), by: .user)
            return yes
        }
    }
}
