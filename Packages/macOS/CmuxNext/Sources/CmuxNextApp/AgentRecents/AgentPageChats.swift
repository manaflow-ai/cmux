import CmuxNextAgentLanes
import Foundation
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextPages
import CmuxNextSidebar

/// The New Tab page's chats. The cards read the app's one Chats feed (acpmux's device chat index,
/// newest few). The All chats list (cx-n0i9; the sidebar has no All chats since 2026-10-10) pages
/// from the daemon on demand (`chats.page`): the socket read and decode run off the main actor,
/// and only one page of rows reaches it. Everything opens through the shared Open Chat path
/// (``ChatsOpenCoordinator``): one click a new workspace with the agent pane, Open in Terminal
/// from a row's right-click menu. Every page also gets the saved environments, which only a New
/// Tab page may read or edit (``AgentPaneEnvironmentRequest``).
@MainActor
final class AgentPageChats {
    private(set) var chats: [AgentPaneDeviceChat] = []
    /// The Recently Closed section's newest items (NewTabClosed).
    var closed: AgentPaneClosedList = .empty
    private(set) var open: (@MainActor (String) -> Void)?
    private(set) var openInTerminal: (@MainActor (String) -> Void)?
    /// View Only from a row's right-click menu (``ChatsOpenCoordinator/open(_:inTerminal:watch:replacing:)``).
    private(set) var watch: (@MainActor (String) -> Void)?
    /// A row of the New Tab page's All chats: the chat opens in that page's tab, which becomes the
    /// chat (`(chat key, page tab key)`, Lawrence 2026-10-11: "like a browser link").
    private(set) var openHere: (@MainActor (String, String) -> Void)?
    private(set) var page: ((AgentPaneChatsQuery) async -> AgentPaneChatsPage?)?
    /// This Mac's saved environments, one store for every page (AgentTabStore.wired); none in a
    /// run with no state folder, where New Tab pages list none.
    var environments: (any AgentPaneEnvironmentStoring)?
    /// A new chat's Sandboxed send (``AgentPaneModel/onSandboxRun``), one runner for every page.
    var sandboxRun: (@MainActor (String, String?, String) async -> [String: Any])?
    /// The signed-in person's platform environment API, through the existing install mint and Rust transport.
    var cloudEnvironment: (@MainActor (AgentPaneCloudEnvironmentRequest) async -> [String: Any])?
    /// A new chat's first send in Cloud (``CloudStartChat``), one runner for every page, given the pane that sent.
    var cloudStart: (@MainActor (AgentPaneView?, AgentPaneCloudStart) async -> [String: Any])?
    /// The app-level waiter on every Sandboxed send's Run, and its notification (``SandboxRunNotices``).
    private(set) var runNotices: SandboxRunNotices?
    /// A Cloud chat's hand-off turn (``CloudHandoffTurnOpener``), one runner for every page, given the pane that asked.
    var handoffTurn: (@MainActor (AgentPaneView?, String) async -> [String: Any])?
    /// The app-level waiter on every hand-off of a chat to a Cloud machine, and its notification.
    private(set) var handoffNotices: HandoffNotices?

    /// A click on banner `id` of a Run or a hand-off; false when it is neither's.
    func openNotice(banner id: String) -> Bool {
        runNotices?.open(banner: id) == true || handoffNotices?.open(banner: id) == true
    }

    /// The app quits: every Run's and hand-off's wait ends (the saved ones resume at the next launch).
    func stopNotices() {
        runNotices?.stop()
        handoffNotices?.stop()
    }

    /// Follows `feed` for every page of `tabs`; cards open through `opener`.
    static func wire(_ tabs: AgentTabStore, to feed: ChatsFeed, opener: ChatsOpenCoordinator) {
        tabs.pageChats.follow(feed, open: { [weak opener] key in opener?.open(key) }) { [weak tabs] in
            guard let tabs else { return [] }
            return Array(tabs.views.values) + tabs.standaloneViews.allObjects
        }
    }

    /// The All chats list's pages come from `environment`'s daemon; rows open through `opener`.
    static func wirePager(_ tabs: AgentTabStore, environment: AcpmuxEnvironment?, opener: ChatsOpenCoordinator) {
        let chats = tabs.pageChats
        if chats.open == nil { chats.open = { [weak opener] key in opener?.open(key) } }
        chats.openInTerminal = { [weak opener] key in opener?.openInTerminal(key) }
        chats.watch = { [weak opener] key in opener?.open(key, watch: true) }
        chats.openHere = { [weak opener] key, page in opener?.open(key, replacing: page) }
        guard let environment else { return }
        chats.page = { query in
            // One bounded page (<= AgentPaneChatsQuery.maximumLimit rows), read and decoded off the main actor.
            guard var page = try? await environment.chatsPage(query) else { return nil }
            page.design = SidebarChatsDesign.tunable.value.rawValue
            return page
        }
    }

    /// The cards follow their window (acpmux sorts and pages; only that window's changes push).
    func follow(_ feed: ChatsFeed, open: @escaping @MainActor (String) -> Void, views: @escaping @MainActor () -> [AgentPaneView]) {
        self.open = open
        let window = feed.windows.window(AcpmuxChatWindows.Spec.newTabCards.window)
        window.follow(self) { [weak self] rows in
            guard let self else { return }
            chats = Self.deviceChats(rows)
            for view in views() { view.deviceChats = chats }
        }
        feed.windows.open(.newTabCards)
        chats = Self.deviceChats(window.rows)
    }

    /// A new page starts with the current chats and closed items.
    func seed(_ view: AgentPaneView) {
        view.deviceChats = chats
        view.recentlyClosed = closed
        view.model.startFolders.environments = environments
        view.model.onSandboxRun = sandboxRun
        view.model.onCloudEnvironment = cloudEnvironment
        if let run = handoffTurn {
            view.model.onCloudHandoffTurn = { @MainActor [weak view] (session: String) async -> [String: Any] in
                await run(view, session)
            }
        } else {
            view.model.onCloudHandoffTurn = nil
        }
        // Written out with its type: Xcode 26.6 could not type the `map` form.
        if let run = cloudStart {
            view.model.onCloudStartChat = { @MainActor [weak view] (start: AgentPaneCloudStart) async -> [String: Any] in
                await run(view, start)
            }
        } else {
            view.model.onCloudStartChat = nil
        }
    }

    /// Sandboxed sends run through `services`' signed-in Cloud client (hq#3367), only while Labs >
    /// Show Preview Features is on and Cloud isn't turned off by policy. Each waits for its Run's
    /// receipt through ``CloudAPIClient/runSandbox(task:agent:timeoutMs:idempotencyKey:teardown:callsMargin:now:)``,
    /// which answers by the task timeout plus teardown whatever the calls do. The Run's wait is
    /// ``SandboxRunNotices``': it goes on after the tab closes and notifies when the Run ends.
    static func wireSandbox(_ tabs: AgentTabStore, services: AppServices) {
        let notices = SandboxRunNotices(services: services)
        tabs.pageChats.runNotices = notices
        tabs.pageChats.cloudStart = CloudStartChat.runner(tabs, services: services)
        tabs.pageChats.cloudEnvironment = { [weak services] request in
            guard let services else { return AgentPaneReply.failure(code: "cloud_disabled", message: "cloud_disabled") }
            return await request.run(
                allowed: !services.registry.disabledFeatures.contains(.cloud) && services.cloud.mayCallCloud,
                connection: services.machines.local.connection, platform: ArtifactsPageProvider.apiBaseURL()) {
                    let team = try await services.cloud.auth.accessTokenTeam(requested: nil)
                    return (try await services.cloud.installIdentity.accessToken(team: team)).accessToken
                }
        }
        notices.start()
        let handoffs = HandoffNotices(services: services)
        tabs.pageChats.handoffNotices = handoffs
        handoffs.start()
        tabs.pageChats.handoffTurn = CloudHandoffTurnOpener.runner(tabs, services: services)
        tabs.pageChats.sandboxRun = { [weak services] task, agent, key in
            guard let services else { return AgentPaneReply.failure(code: "cloud_disabled", message: "cloud_disabled") }
            // Read before any wait, while the pane holds the send: its tab may close before the create answers.
            let incognito = notices.sendIsIncognito(key: key)
            // Cloud turned off by policy, or the managed team it requires missing: a definite
            // refusal, nothing was asked of the server.
            guard !services.registry.disabledFeatures.contains(.cloud), services.cloud.mayCallCloud else {
                return AgentPaneReply.failure(code: "cloud_disabled", message: "cloud_disabled")
            }
            // Not behind Labs (Leo, 2026-10-30: "i dont like putting so much stuff in labs"): the
            // person picked Sandboxed and sent, Cloud is allowed and they are signed in.
            guard services.cloud.isSignedIn else { return AgentPaneReply.failure(code: "not_signed_in", message: "not_signed_in") }
            // The send, its create's retry and its waits stay with the team it began with (and the
            // create's retry with its account: CloudAPIClient.runSandbox).
            // The Run is followed in the team it was created in (SandboxRunNotices).
            let team = await services.cloud.api.currentTeam()
            let api = services.cloud.api.pinningTeam(team)
            let follow: @Sendable (String) async throws -> Data = { id in
                try await notices.follow(id: id, task: task, key: key, team: team, incognito: incognito)
            }
            return await AgentPaneReply.sandbox({ try await api.runSandbox(task: task, agent: agent, idempotencyKey: key, follow: follow) },
                                                code: AgentPageChats.sandboxCode)
        }
    }

    /// A Sandboxed send's failure as the page's code (AgentPaneReply keeps only the codes it words).
    /// A refusal answered before the server stored anything is definite, so the tab may send again.
    nonisolated static func sandboxCode(_ error: any Error) -> String {
        switch error as? CloudAPIError {
        // An expired or revoked session: sign in again.
        case .notSignedIn?, .http(401, _, _, _, _)?: "not_signed_in"
        // A rate limit, or no backend configured: nothing was stored or sent.
        case .http(429, _, _, _, _)?, .noBackend?: "unavailable_now"
        // A Run API with no sandboxed Runs yet asks for a repository source and recipe. It refuses the
        // body before storing anything, so Sandboxed isn't enabled here, and the tab may send again.
        case .http(400, "run_source_required"?, _, _, _)?, .http(400, "run_recipe_required"?, _, _, _)?:
            "run_sandbox_unavailable"
        case let other?: other.code
        case nil: "unavailable"
        }
    }

    /// The newest chats, as the page cards take them.
    static func deviceChats(_ chats: [AcpmuxChat]) -> [AgentPaneDeviceChat] {
        chats.prefix(AgentPaneDeviceChat.maximumPushed).map {
            AgentPaneDeviceChat(key: $0.id, harness: $0.harness, title: $0.title, updatedAt: $0.updatedAt)
        }
    }
}
