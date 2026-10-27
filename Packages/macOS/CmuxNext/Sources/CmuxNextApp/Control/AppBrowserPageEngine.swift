import CmuxNextControl
import CmuxNextSettings
import CmuxNextWakeups

/// `browser.page.*` (CmuxNextControl/Browser) for the app's browser tabs.
nonisolated struct AppBrowserPageEngine: BrowserPageEngine {
    unowned let services: AppServices
    /// The app's main-thread scheduler: the agent cursor is posted on it.
    private let mainWork: MainWorkScheduler

    @MainActor init(services: AppServices) {
        self.services = services
        mainWork = services.mainWork
    }

    func run(_ operation: BrowserPageOperation, tabID: String, url: String?) async throws -> JSONValue {
        try await AppBrowserPage.run(operation, tabID: tabID, services: services)
    }

    /// The agent cursor is an agent's work: one automation task, in order with the request's other posts, so it
    /// never takes the person's frame (p06-scheduler.md section D).
    func announce(_ input: BrowserPageAgentInput, tabID: String) async {
        mainWork.postFromAnyThread(.automation, owner: "browser.page.agent_cursor") { [services] in
            services.browserHost?.pageInputCursor.publish(input, tabID: tabID)
        }
    }
}
