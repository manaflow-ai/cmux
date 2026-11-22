import AppKit
import typealias CmuxNextBridge.StripTabID
import CmuxHomeCore
import CmuxNextActions
import CmuxNextAgentCursor
import CmuxNextCloud
import CmuxNextHomeEngine
import CmuxNextHostedChief
import CmuxNextRemoteView
import OSLog

extension InternalPageID {
    /// The Chief's profile page with its computer (cmux issue 31488): one pane tab per conversation.
    nonisolated static let chiefComputer = InternalPageID(rawValue: "chief-computer")
}

/// Owns the Chief's large computer pages in the pane beside Home. The settings popover's Expand and
/// the palette's Chief: Toggle Computer open them. Each tab's route is its conversation, so a relaunched tab shows the same Chief.
@MainActor
final class ChiefComputerPageService: InternalPageProvider {
    static let toggleActionID = ChiefComputerWiring.toggleActionID

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

    /// Draws the branded agent cursor over a Chief's screen: a Linux screen capture does not include it.
    static func pointerPainter(chief: @escaping () -> String) -> (CALayer) -> (CGPoint?) -> Void {
        { layer in
            let session = "chief-computer"
            let host = AgentCursorLayerHost(hostLayer: layer, color: AgentCursorStack.sessionColor, label: { _ in chief() })
            return { point in
                guard let point else { return host.apply(.remove(session: session)) }
                host.apply(.confine(session: session, bounds: layer.bounds))
                host.apply(.place(session: session, point: point))
            }
        }
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

    /// Whether `window` has this Chief's page on screen: the chat's popup then stays away. A page
    /// parked behind another tab does not count, so the chat keeps its live view.
    func shows(_ conversation: String, in window: NSWindow?) -> Bool {
        routes.contains { key, route in
            guard route == conversation, let view = views[key], let window else { return false }
            return view.window === window && !view.isHiddenOrHasHiddenAncestor
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
        ChiefComputerWiring.wirePage(view, host: services, conversation: conversation)
        view.onClose = { [weak self, weak services] in
            if let window = services?.windows.active { _ = self?.closeShown(in: window) }
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

/// The Chief's computer wiring (CmuxNextHostedChief's ChiefComputerWiring) reads the app through this.
extension AppServices: ChiefComputerHost {
    func cloudChiefID(_ conversation: String) -> String? { home.cloudChiefs.chief(for: conversation)?.id }
    func chiefDisplayName(_ conversation: String) -> String { home.chiefName(of: ConversationID(conversation)) ?? HomeStrings.chiefName }
    var defaultChiefConversation: String? { home.defaultChiefConversation }
    var cloudPlanID: String? { machines.cloudLimits?.planId }
    var cloudMachinesListed: Bool { machines.cloudLimits != nil }
    var cloudMachineRecords: [(id: String, machine: CloudMachine)] { machines.cloud.map { ($0.machineID, $0.machine) } }
    func cloudMachineRecord(_ id: String) -> CloudMachine? { machines.session(id)?.machine }
    var computerControl: ChiefComputerControlStore { cloud.computerControl }
    var cloudMachineAPI: CloudAPIClient { cloud.machineAPI }
    var chiefBrainRoute: HomeChiefHostedEngine.Send { home.hostedChief.brainRoute }
    func createCloudMachine(name: String?) async throws -> String { try await cloud.createMachine(name: name, startedByPerson: true).machineID }
    func showChiefSettings() { try? settingsWindow.show(section: nil, focus: true, route: "#/settings/chief") }
    func upgradeToPaidPlan() {
        // task-owner: one Checkout start; ends when it opens
        Task { await paidPlanUpgrade().start(plan: "pro", source: .cloudRefusal, fallback: nil) }
    }
    func moveDefaultChiefToCloud() {
        _ = registry.perform(ChiefMoveHandlers.actionID, invocation: ActionInvocation(arguments: ["target": .string(ChiefMoveTargets.cloudID)], origin: .user))
    }
    func chiefComputerPointerPainter(chief: @escaping () -> String) -> (CALayer) -> (CGPoint?) -> Void {
        ChiefComputerPageService.pointerPainter(chief: chief)
    }

    func chiefComputerLiveFeed(machine: String, name: String, agentActs: @escaping () -> Bool) -> (any HomeChiefComputerLiveFeed)? {
        guard machines.session(machine)?.machine.opensCarrierDesktop == true else {
            RemoteDesktopWatchFeed.logger.error("computer live: machine serves no carrier desktop")
            return nil
        }
        guard let transport = cloudDesktopRdTransport(machine: machine)?(false) else {
            RemoteDesktopWatchFeed.logger.error("computer live: no transport")
            return nil
        }
        return RemoteDesktopWatchFeed(name: name, transport: transport, agentActs: agentActs)
    }
}

extension RemoteDesktopWatchFeed: HomeChiefComputerLiveFeed {}
