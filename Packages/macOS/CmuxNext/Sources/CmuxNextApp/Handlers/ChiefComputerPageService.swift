import AppKit
import typealias CmuxNextBridge.StripTabID
import CmuxHomeCore
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextHomeEngine

extension InternalPageID {
    /// The Chief's profile page with its computer (cmux issue 31488): one pane tab per conversation.
    nonisolated static let chiefComputer = InternalPageID(rawValue: "chief-computer")
}

/// Owns the Chief profile tabs in the pane beside Home. The Home header's Computer toggle and the
/// chat's popup open them. Each tab's route is its conversation, so a relaunched tab shows the same Chief.
@MainActor
final class ChiefComputerPageService: InternalPageProvider {
    static let toggleActionID: ActionID = "chief.toggleComputer"

    private weak var services: AppServices?
    private var routes: [String: String] = [:]
    private var nextRoute: String?
    private var avatars: [String: (picture: NSImage?, text: String?)] = [:]
    private var views: [String: HomeChiefProfileView] = [:]

    init(services: AppServices) {
        self.services = services
    }

    var page: InternalPageID { .chiefComputer }
    var title: String { HomeEngineStrings.computerPageTitle }
    var symbol: String { "desktopcomputer" }

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let service = ChiefComputerPageService(services: context.services)
        context.services.pages.register(service)
        registry.bindEffect(toggleActionID, requires: nil, effect: { invocation in
            guard let window = context.services.windows.active else { return .refused(RefusalStrings.noWindowOpen) }
            if invocation.arguments["open"]?.stringValue != "1", service.closeShown(in: window) { return .done }
            // The palette names no conversation: the Chief Home shows first.
            guard let conversation = invocation.arguments["conversation"]?.stringValue ?? context.services.home.defaultChiefConversation, !conversation.isEmpty,
                  service.open(conversation, in: window, focus: invocation.allowsViewChange) != nil else {
                return .refused(RefusalStrings.noWindowOpen)
            }
            return .done
        })
    }

    /// What the page and the chat's popup read: the plan and the Chief's owner route. A Chief that
    /// does not run in the Cloud has no agent id, so its status reads as none.
    static func source(services: AppServices, conversation: String) -> HomeChiefComputerSection.Source {
        let service = services.home
        let id = ConversationID(conversation)
        return .init(paid: { [weak services] in services?.machines.cloudLimits?.paysForCloud == true },
                     chief: { [weak service] in service?.chiefName(of: id) ?? HomeStrings.chiefName },
                     route: HomeChiefComputerRoute(agent: { [weak services] in services?.home.cloudChiefs.chief(for: conversation)?.id },
                                                   send: service.hostedChief.brainRoute))
    }

    /// The Home chat's avatar for its Chief, which the page shows too.
    func setAvatar(conversation: String, picture: NSImage?, text: String?) {
        avatars[conversation] = (picture, text)
        for (key, route) in routes where route == conversation { views[key]?.setAvatar(picture: picture, text: text) }
    }

    @discardableResult
    func open(_ conversation: String, in window: WindowController?, focus: Bool) -> String? {
        guard let services, let window, let content = window.workspaceContent else { return nil }
        for model in content.modelPanes {
            let keys = services.pages.tabIDs(in: model.id) + model.tabs.compactMap { services.pages.storeKey(of: $0.id) }
            if let shown = keys.first(where: { routes[$0] == conversation }) {
                if focus, let pane = content.controller(for: model) {
                    pane.select(services.pages.stripID(showing: shown, in: pane) ?? StripTabID(shown))
                    pane.focusContent()
                }
                return shown
            }
        }
        nextRoute = conversation
        defer { nextRoute = nil }
        guard services.pages.openNew(.chiefComputer, in: window, focus: focus) != nil else { return nil }
        return routes.first { $0.value == conversation }?.key
    }

    /// Whether the workspace `window` names shows this Chief's page: the chat's popup then stays away.
    func shows(_ conversation: String, in window: WindowController) -> Bool {
        guard let content = window.workspaceContent, let services else { return false }
        return content.modelPanes.contains { model in
            let keys = services.pages.tabIDs(in: model.id) + model.tabs.compactMap { services.pages.storeKey(of: $0.id) }
            return keys.contains { routes[$0] == conversation }
        }
    }

    /// Whether the workspace `window` names shows a profile tab: an observable read.
    func isShown(in window: WindowController) -> Bool {
        _ = window.state.workspaceID
        guard let content = window.workspaceContent, let services else { return false }
        if !Self.tabs(in: content.workspace).isEmpty { return true }
        return services.pages.tab(of: .chiefComputer, inPanes: content.modelPanes.map(\.id)) != nil
    }

    /// Closes the profile tabs of the workspace `window` names; false when it shows none.
    func closeShown(in window: WindowController) -> Bool {
        guard let services, let content = window.workspaceContent else { return false }
        var closed = false
        for model in content.modelPanes {
            guard let pane = content.controller(for: model) else { continue }
            let store = model.tabs.filter { $0.page == InternalPageID.chiefComputer.rawValue }.map { StripTabID($0.id) }
            let local = services.pages.tabIDs(in: model.id).filter { LocalPageTab.page(of: $0) == .chiefComputer }.map { StripTabID($0) }
            guard !(store + local).isEmpty else { continue }
            pane.close(store + local)
            closed = true
        }
        return closed
    }

    private static func tabs(in workspace: WorkspaceModel) -> [TabModel] {
        workspace.screens.flatMap(\.panes).flatMap(\.tabs).filter { $0.page == InternalPageID.chiefComputer.rawValue }
    }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        let conversation = routes[key] ?? nextRoute ?? ""
        routes[key] = conversation
        let view = HomeChiefProfileView()
        views[key] = view
        guard let services else { return view }
        let service = services.home
        let id = ConversationID(conversation)
        view.computer.source = Self.source(services: services, conversation: conversation)
        view.paid = { [weak services] in services?.machines.cloudLimits?.paysForCloud == true }
        view.cloudChief = { [weak services] in services?.home.cloudChiefs.chief(for: conversation) != nil }
        view.name = { [weak service] in service?.chiefName(of: id) ?? HomeStrings.chiefName }
        view.place = { [weak services] in
            services?.home.cloudChiefs.chief(for: conversation) != nil ? HomeEngineStrings.runsInCloud : HomeEngineStrings.runsHere
        }
        view.onClose = { [weak self, weak services] in
            if let window = services?.windows.active { _ = self?.closeShown(in: window) }
        }
        view.onUpgrade = { [weak services] in
            // task-owner: one Checkout start; ends when it opens
            Task { await services?.paidPlanUpgrade().start(plan: "pro", source: .cloudRefusal, fallback: nil) }
        }
        view.onMoveToCloud = { [weak services] in
            _ = services?.registry.perform(ChiefMoveHandlers.actionID, invocation: ActionInvocation(arguments: ["target": .string(ChiefMoveTargets.cloudID)], origin: .user))
        }
        view.onSettings = { [weak services] in
            try? services?.settingsWindow.show(section: nil, focus: true, route: "#/settings/chief")
        }
        if let avatar = avatars[conversation] { view.setAvatar(picture: avatar.picture, text: avatar.text) }
        return view
    }

    func tabClosed(_ key: String) {
        routes[key] = nil
        views[key] = nil
    }

    func route(for key: String) -> String? { routes[key] }

    func restore(_ route: String, for key: String) {
        routes[key] = route
    }
}
