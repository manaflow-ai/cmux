import CmuxNextActions
import CmuxNextDaemon
import CmuxNextHome
import CmuxNextHomeEngine

// A Chief's cards (cmux issue 25830, HomeChiefCardActions): one-line forwards to the App's owners.
extension AppServices: HomeChiefCardHost {
    func chiefCardBrowserTab() -> String? { HomeDock.chiefBrowserTab(home: home.homeWorkspace, agentProfile: AgentBrowserProfile.id) }
    func chiefCardReveal(tab id: String) -> Bool { revealTab(id, intent: .bringForward) }
    func chiefCardOpenDesktop(machine id: String) { _ = registry.perform("cloudOpenDesktop", invocation: ActionInvocation(target: ActionTargetRef(kind: .machine, id: id), origin: .user)) }
    func chiefCardSave(site: String, username: String, password: String) async -> Bool { await ChiefSecureStore().saveInBackground(site: site, username: username, password: password) }
    func chiefCardStoredSites() async -> [String] { await ChiefSecureStore().sitesInBackground() }
}
