import CmuxNextBrowser
import CmuxNextControl
import CmuxNextWakeups
import CmuxNextWorkspaceRepair
import Foundation
import CmuxNextCompat

/// openBrowser's optional `profile` argument (plans/cmux-next/passwords.md,
/// section 3.4). "agent" asks for the clean agent profile: one profile with a
/// fixed id that cmux creates on first use, with no extensions and no cookies
/// shared with the person's profiles, so an agent can drive its pages while
/// the interim extension guard refuses tabs in profiles with extensions. A
/// session the person wants the agent to use goes through the Secure sign-in
/// sheet. Any other value must name an existing profile; an unknown one is
/// refused rather than falling back to the workspace's profile.
enum AgentBrowserProfile {
    static let id = BrowserPageService.agentBrowserProfileID

    static var name: String {
        String(localized: "handlers.misc.agentBrowserProfile.name", defaultValue: "Agents", table: "MiscHandlers", bundle: .module.inAppLanguage)
    }

    /// The agent profile's id, created when missing (an existing record is
    /// kept). With daemon-owned records the create reply can arrive before
    /// the record reaches this app's mirror, and a tab opened then would fall
    /// back to the workspace's profile (the cascade only takes known ids), so
    /// this waits for the record to be reported, at most `deadline`.
    static func ensure(_ profiles: BrowserProfileService, deadline: Duration = .seconds(5)) async throws -> String {
        if profiles.isKnown(id) { return id }
        _ = try await profiles.createProfile(id: id, name: name, color: nil, icon: nil)
        try await profiles.awaitReported(id, deadline: deadline)
        return id
    }

    /// An agent's tab in the agents' own workspace on the home daemon, never shown or focused
    /// (``EmptyWorkspaceRepair/openAgentBrowserTab``): the agent profile's, marked agent-driven.
    @MainActor static func openTab(url: String?, inWorkspace workspace: String?, named name: String, services: AppServices) async throws -> (tab: String, workspace: String) {
        guard case .open(let choice) = services.cache.browserTabs.resolve(requested: nil) else { throw ControlError(code: "unavailable", message: "No browser engine can open the agent's tab") }
        let opened = try await services.machines.emptyWorkspaceRepair(services.daemon.machineID, local: services.emptyWorkspaces).openAgentBrowserTab(
            url: url, engine: choice.engine, profileID: try await ensure(services.browserProfiles), inWorkspace: workspace.flatMap { services.workspace(id: $0) },
            key: BrowserPageService.agentWorkspaceKey, name: name, on: services.daemon.connection)
        services.cache.browserTabs.opened(choice, opened.surface, on: services.daemon)
        services.cache.markAgentDriven(surface: opened.surface)
        return (opened.tab, opened.workspace)
    }
}
