import AppKit
import typealias CmuxNextBridge.StripTabID
import CmuxHomeCore
import CmuxNextActions
import CmuxNextAgentCursor
import CmuxNextCloud
import CmuxNextDaemon
import CmuxNextHomeEngine
import CmuxNextHostedChief
import CmuxNextRemoteView
import OSLog

extension InternalPageID {
    /// The Chief's profile page with its computer (cmux issue 31488): one pane tab per conversation.
    nonisolated static let chiefComputer = InternalPageID(rawValue: "chief-computer")
}

/// Owns the Chief's large computer pages in the pane beside Home. The profile panel's Expand and
/// the palette's Chief: Toggle Computer open them. Each tab's route is its conversation, so a relaunched tab shows the same Chief.
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

    /// The Chief's computer key: a Cloud Chief's agent id, else a Chief of this Mac's own computer (`local:<conversation>`).
    static func computerKey(_ services: AppServices, _ conversation: String) -> String? {
        services.home.cloudChiefs.chief(for: conversation)?.id ?? HomeChiefComputerRoute.localKey(conversation)
    }

    /// What the page and the chat's popup read: the plan and the Chief's owner route, a Chief of this Mac's own computer too.
    static func source(services: AppServices, conversation: String) -> HomeChiefComputerSection.Source {
        let service = services.home
        let id = ConversationID(conversation)
        let route = HomeChiefComputerRoute(agent: { [weak services] in services.flatMap { computerKey($0, conversation) } },
                                           send: ChiefComputerControlClient.feeding(service.hostedChief.brainRoute, into: services.cloud.computerControl))
        let pointer = MachinePointer()
        return .init(paid: { [weak services] in HomeChiefComputer.planAllows(paysForCloud: services?.machines.cloudLimits?.paysForCloud) },
                     chief: { [weak service] in service?.chiefName(of: id) ?? HomeStrings.chiefName },
                     status: { [weak services] in
                         if let services, let machine = attachedMachine(services, conversation) { return machineStatus(services, machine) }
                         return await route.status()
                     },
                     screen: { [weak services] in
                         if let services, let machine = attachedMachine(services, conversation) { return await machineScreen(services, machine, pointer) }
                         return await route.screen()
                     },
                     pointer: { [weak services] in
                         guard let services, let machine = attachedMachine(services, conversation) else { return nil }
                         let control = services.cloud.computerControl
                         return control.isInUse(machine: machine) && control.state(.machine(machine))?.holder != .human ? pointer.point : nil
                     },
                     live: { [weak services] in
                         guard let services, let machine = attachedMachine(services, conversation) else { return nil }
                         guard services.machines.session(machine)?.machine.opensCarrierDesktop == true else {
                             screenLogger.error("computer live: machine serves no carrier desktop")
                             return nil
                         }
                         guard let transport = services.cloudDesktopRdTransport(machine: machine)?(false) else {
                             screenLogger.error("computer live: no transport")
                             return nil
                         }
                         let control = services.cloud.computerControl
                         return MachineLiveFeed(name: machineName(conversation), transport: transport) { [weak control] in
                             guard let control else { return false }
                             return control.isInUse(machine: machine) && control.state(.machine(machine))?.holder != .human
                         }
                     })
    }

    /// The name of a Cloud Chief's computer: its normal Cloud machine is found by it, so it holds across relaunches.
    static func machineName(_ conversation: String) -> String { "Chief \(conversation.suffix(8))" }

    /// The normal Cloud machine a Chief uses as its computer: a Cloud Chief's by name, a Chief of this Mac's its card's pick; nil for none.
    static func attachedMachine(_ services: AppServices, _ conversation: String) -> String? {
        guard services.home.cloudChiefs.chief(for: conversation) != nil else { return services.cloud.computerControl.attachedMachines[conversation] }
        let name = machineName(conversation)
        return services.machines.cloud.first { $0.machine.title == name && $0.machine.status != .destroyed && $0.machine.status != .deleting }?.machineID
    }

    /// The machine's state from the app's own machine list, in the words ``HomeChiefComputer`` reads.
    private static func machineStatus(_ services: AppServices, _ machine: String) -> HomeChiefComputer.Status? {
        guard let status = services.machines.session(machine)?.machine.status else { return nil }
        let state = switch status {
        case .provisioning: "running"  // the list can say so after it boots: the screen read is what tells
        case .pausing: "suspending"
        default: status.rawValue
        }
        return HomeChiefComputer.Status(used: true, computer: (machine, state), acting: services.cloud.computerControl.isInUse(machine: machine))
    }

    /// The machine's screen by the route of `cmux cloud computer screenshot`: exec writes it, the file read brings it back.
    private static func machineScreen(_ services: AppServices, _ machine: String, _ pointer: MachinePointer) async -> CGImage? {
        let api = services.cloud.machineAPI
        do {
            let ran = try await api.exec(machine, command: HomeChiefComputerRoute.machineScreenCommand, timeoutMs: 20_000)
            guard ran.exitCode == 0 else {
                screenLogger.error("computer screen: capture exited \(ran.exitCode, privacy: .public)")
                return nil
            }
            let file = try await api.readFile(machine, path: HomeChiefComputerRoute.machineScreenFile)
            pointer.point = HomeChiefComputerRoute.machinePointer(ran.stdout)
            return await HomeChiefComputerRoute.image(base64: file.dataBase64)
        } catch {
            if !Task.isCancelled { screenLogger.error("computer screen: read failed: \(String(describing: error), privacy: .public)") }
            return nil
        }
    }

    private static let screenLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "chief.computer")

    /// A Chief's Cloud machine's desktop stream, watching only: the same `cmux-rd` session Open Desktop's viewer runs.
    /// The person's input while they hold control still goes through the screen's own route.
    private final class MachineLiveFeed: HomeChiefComputerLiveFeed {
        private let pane: RemoteDesktopPane
        private let transport: RemoteRdStreamTransport
        private let agentActs: () -> Bool
        private var cursor: RemoteCursorState?
        var onChange: (() -> Void)?

        init(name: String, transport: RemoteRdStreamTransport, agentActs: @escaping () -> Bool) {
            self.transport = transport
            self.agentActs = agentActs
            pane = RemoteDesktopPane(hostName: name, source: transport, inputSink: nil, initialMode: .view, scaling: .fit,
                                     viaCloudTunnel: true, modeControl: .takeOver)
            pane.view.showsChrome = false
            pane.onStateChange = { [weak self] in
                guard let self else { return }
                let line = debugStatus
                if line != lastStatus {
                    lastStatus = line
                    ChiefComputerPageService.screenLogger.notice("computer live: \(line, privacy: .public)")
                }
                onChange?()
            }
            pane.onCursor = { [weak self] in
                self?.cursor = $0
                self?.onChange?()
            }
            pane.start()
            transport.connect()
        }

        private var lastStatus = ""
        var debugStatus: String { "\(String(describing: pane.state.status)) hasFrame=\(pane.state.hasFrame) overlay=\(String(describing: pane.state.overlay))" }
        var view: NSView { pane.view }
        var isLive: Bool { pane.isShowingFrames }
        var pixels: CGSize { pane.framePixels }
        var pointer: CGPoint? {
            guard agentActs(), let cursor, cursor.visible else { return nil }
            return cursor.position
        }

        func stop() {
            pane.stop()
            transport.stop()
        }
    }

    /// Where the last screen read found the pointer of a Chief's Cloud machine.
    @MainActor private final class MachinePointer {
        var point: CGPoint?
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
        Self.wire(view, services: services, conversation: conversation)
        // The expanded computer's control bar (Take Over / Give Back): a Cloud Chief's own sandbox.
        let machine = Self.attachedMachine(services, conversation)
        view.control = services.chiefComputerControlSource(agent: machine == nil ? Self.computerKey(services, conversation) : nil, machine: machine)
        view.place = { [weak services] in
            services?.home.cloudChiefs.chief(for: conversation) != nil ? HomeEngineStrings.runsInCloud : HomeEngineStrings.runsHere
        }
        view.onClose = { [weak self, weak services] in
            if let window = services?.windows.active { _ = self?.closeShown(in: window) }
        }
        view.onSettings = { [weak services] in
            try? services?.settingsWindow.show(section: nil, focus: true, route: "#/settings/chief")
        }
        if let avatar = avatars[conversation] { view.setAvatar(picture: avatar.picture, text: avatar.text) }
        return view
    }

    /// What this page and the Home chat's profile panel share: the computer, the plan, the Chief, Upgrade and Move to Cloud.
    static func wire(_ view: HomeChiefProfileView, services: AppServices, conversation: String) {
        let service = services.home
        let id = ConversationID(conversation)
        view.computer.source = Self.source(services: services, conversation: conversation)
        view.paid = { [weak services] in HomeChiefComputer.planAllows(paysForCloud: services?.machines.cloudLimits?.paysForCloud) }
        view.cloudChief = { [weak services] in services?.home.cloudChiefs.chief(for: conversation) != nil }
        view.onProvision = { [weak services] in  // a Cloud Chief: a normal Cloud machine under its name
            guard let services else { throw CancellationError() }
            _ = try await services.cloud.createMachine(name: machineName(conversation), startedByPerson: true)
        }
        view.makeMachine = { [weak services] in  // a Chief of this Mac: a normal Cloud machine, a new one each time
            guard let services else { throw CancellationError() }
            return try await services.cloud.createMachine(name: nil, startedByPerson: true).machineID
        }
        view.name = { [weak service] in service?.chiefName(of: id) ?? HomeStrings.chiefName }
        view.onUpgrade = { [weak services] in
            // task-owner: one Checkout start; ends when it opens
            Task { await services?.paidPlanUpgrade().start(plan: "pro", source: .cloudRefusal, fallback: nil) }
        }
        view.onMoveToCloud = { [weak services] in
            // The move runs on the app's Chief; another Chief's page goes to the settings instead.
            guard services?.home.defaultChiefConversation == conversation else {
                try? services?.settingsWindow.show(section: nil, focus: true, route: "#/settings/chief")
                return
            }
            _ = services?.registry.perform(ChiefMoveHandlers.actionID, invocation: ActionInvocation(arguments: ["target": .string(ChiefMoveTargets.cloudID)], origin: .user))
        }
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
