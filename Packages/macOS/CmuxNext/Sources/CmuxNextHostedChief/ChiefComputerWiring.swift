public import AppKit
public import CmuxNextActions
public import CmuxNextCloud
public import CmuxNextHomeEngine
import OSLog

/// What the Chief's computer wiring reads from the app (cmux issue 31488). The composition root
/// implements it on its services; everything else about the computer (the page's and the popover's
/// profile, the chat's popup, which machine a Chief uses, its status, screen and pointer) is here.
@MainActor
public protocol ChiefComputerHost: AnyObject, Sendable {
    /// A Cloud Chief's agent id; nil for a Chief of this Mac.
    func cloudChiefID(_ conversation: String) -> String?
    /// The Chief's name as the app shows it.
    func chiefDisplayName(_ conversation: String) -> String
    /// The app's own Chief's conversation (Move to Cloud runs on it).
    var defaultChiefConversation: String? { get }
    /// The team's plan id; nil before it is read.
    var cloudPlanID: String? { get }
    /// Whether the Cloud machine list (and its plan) has been read.
    var cloudMachinesListed: Bool { get }
    /// The loaded Cloud machines, by id.
    var cloudMachineRecords: [(id: String, machine: CloudMachine)] { get }
    /// One loaded Cloud machine's record.
    func cloudMachineRecord(_ id: String) -> CloudMachine?
    /// Who drives each Chief's computer.
    var computerControl: ChiefComputerControlStore { get }
    var cloudMachineAPI: CloudDaemon { get }
    /// The hosted Chief's brain route.
    var chiefBrainRoute: HomeChiefHostedEngine.Send { get }
    var registry: ActionRegistry { get }
    /// A watching-only live stream of `machine`'s desktop; nil when it serves none.
    func chiefComputerLiveFeed(machine: String, name: String, agentActs: @escaping () -> Bool) -> (any HomeChiefComputerLiveFeed)?
    /// Draws the branded agent cursor, labelled with the Chief's name, over its screen.
    func chiefComputerPointerPainter(chief: @escaping () -> String) -> (CALayer) -> (CGPoint?) -> Void
    /// Creates a normal Cloud machine (named, or the next free name) as the person's own run; its id.
    func createCloudMachine(name: String?) async throws -> String
    func chiefComputerControlSource(agent: String?, machine: String?) -> HomeChiefComputerControlSource?
    func openChiefComputerDesktop(machine: String)
    func showChiefSettings()
    /// Starts the paid plan's Checkout (Pro) from a Cloud refusal; returns once it opens.
    func upgradeToPaidPlan() async
    func moveDefaultChiefToCloud()
}

/// The Chief's computer, wired to a ``ChiefComputerHost``: what the expanded page, the settings popover's
/// profile and the chat's popup share.
@MainActor
public struct ChiefComputerWiring {
    public init() {}
    public static let toggleActionID: ActionID = "chief.toggleComputer"
    static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "chief.computer")

    /// The Chief's computer key: a Cloud Chief's agent id, else a Chief of this Mac's own computer (`local:<conversation>`).
    public static func computerKey(_ host: any ChiefComputerHost, _ conversation: String) -> String? {
        host.cloudChiefID(conversation) ?? HomeChiefComputerRoute.localKey(conversation)
    }

    /// The name of a Cloud Chief's computer: its normal Cloud machine is found by it, so it holds across relaunches.
    public static func machineName(_ conversation: String) -> String { "Chief \(conversation.suffix(8))" }

    /// The normal Cloud machine a Chief uses as its computer: a Cloud Chief's by name, a Chief of this Mac's its card's pick; nil for none.
    public static func attachedMachine(_ host: any ChiefComputerHost, _ conversation: String) -> String? {
        guard host.cloudChiefID(conversation) != nil else { return host.computerControl.attachedMachines[conversation] }
        let name = machineName(conversation)
        return host.cloudMachineRecords.first { $0.machine.title == name && $0.machine.status != .destroyed && $0.machine.status != .deleting }?.id
    }

    /// Whether the card's pick (`machine:<id>`, or a bare id) names a Cloud machine the loaded list no longer has.
    /// Before the first list (`listed` false) nothing is gone, and a pick that is not a Cloud machine never is.
    public static func machineGone(_ picked: String, listed: Bool, in machines: [String]) -> Bool {
        guard listed else { return false }
        let id = picked.hasPrefix("machine:") ? String(picked.dropFirst("machine:".count)) : picked
        guard id.hasPrefix("vm_") else { return false }
        return !machines.contains(id)
    }

    /// Whether the Chief, not the person, acts on `machine` now.
    static func agentActs(_ host: any ChiefComputerHost, _ machine: String) -> Bool {
        let control = host.computerControl
        return control.isInUse(machine: machine) && control.state(.machine(machine))?.holder != .human
    }

    /// What the page and the chat's popup read: the plan and the Chief's owner route, a Chief of this Mac's own computer too.
    public static func source(host: any ChiefComputerHost, conversation: String) -> HomeChiefComputerSection.Source {
        let route = HomeChiefComputerRoute(agent: { [weak host] in host.flatMap { computerKey($0, conversation) } },
                                           send: ChiefComputerControlClient.feeding(host.chiefBrainRoute, into: host.computerControl))
        let pointer = MachinePointer()
        return .init(paid: { [weak host] in HomeChiefComputer.planAllows(planId: host?.cloudPlanID) },
                     chief: { [weak host] in host?.chiefDisplayName(conversation) ?? HomeStrings.chiefName },
                     status: { [weak host] in
                         if let host, let machine = attachedMachine(host, conversation) { return machineStatus(host, machine) }
                         return await route.status()
                     },
                     screen: { [weak host] in
                         if let host, let machine = attachedMachine(host, conversation) { return await machineScreen(host, machine, pointer) }
                         return await route.screen()
                     },
                     pointer: { [weak host] in
                         guard let host, let machine = attachedMachine(host, conversation) else { return nil }
                         return agentActs(host, machine) ? pointer.point : nil
                     },
                     live: { [weak host] in
                         guard let host, let machine = attachedMachine(host, conversation) else { return nil }
                         return host.chiefComputerLiveFeed(machine: machine, name: machineName(conversation)) { [weak host] in
                             host.map { agentActs($0, machine) } ?? false
                         }
                     })
    }

    /// The machine's state from the app's own machine list, in the words ``HomeChiefComputer`` reads.
    static func machineStatus(_ host: any ChiefComputerHost, _ machine: String) -> HomeChiefComputer.Status? {
        guard let status = host.cloudMachineRecord(machine)?.status else { return nil }
        let state = switch status {
        case .provisioning: "running"  // the list can say so after it boots: the screen read is what tells
        case .pausing: "suspending"
        default: status.rawValue
        }
        return HomeChiefComputer.Status(used: true, computer: (machine, state), acting: host.computerControl.isInUse(machine: machine))
    }

    /// The machine's screen by the route of `cmux cloud computer screenshot`: exec prints it inline, the file read only when it did not.
    static func machineScreen(_ host: any ChiefComputerHost, _ machine: String, _ pointer: MachinePointer) async -> CGImage? {
        let api = host.cloudMachineAPI
        do {
            let ran = try await api.exec(machine, command: HomeChiefComputerRoute.machineScreenCommand, timeoutMs: 20_000)
            guard ran.exitCode == 0 else {
                logger.error("computer screen: capture exited \(ran.exitCode, privacy: .public)")
                return nil
            }
            pointer.point = HomeChiefComputerRoute.machinePointer(ran.stdout)
            if let frame = HomeChiefComputerRoute.machineFrame(ran.stdout), let image = await HomeChiefComputerRoute.image(base64: frame) {
                return image
            }
            let file = try await api.readFile(machine, path: HomeChiefComputerRoute.machineScreenFile)
            return await HomeChiefComputerRoute.image(base64: file.dataBase64)
        } catch {
            if !Task.isCancelled { logger.error("computer screen: read failed: \(String(describing: error), privacy: .public)") }
            return nil
        }
    }

    /// Where the last screen read found the pointer of a Chief's Cloud machine.
    final class MachinePointer {
        var point: CGPoint?
    }

    /// What the expanded page and the settings popover's profile share: the computer, the plan, the Chief, Upgrade and Move to Cloud.
    public static func wire(_ view: HomeChiefProfileView, host: any ChiefComputerHost, conversation: String) {
        view.computer.source = source(host: host, conversation: conversation)
        view.paid = { [weak host] in HomeChiefComputer.planAllows(planId: host?.cloudPlanID) }
        view.cloudChief = { [weak host] in host?.cloudChiefID(conversation) != nil }
        view.onProvision = { [weak host] in  // a Cloud Chief: a normal Cloud machine under its name
            guard let host else { throw CancellationError() }
            _ = try await host.createCloudMachine(name: machineName(conversation))
        }
        view.makeMachine = { [weak host] in  // a Chief of this Mac: a normal Cloud machine, a new one each time
            guard let host else { throw CancellationError() }
            return try await host.createCloudMachine(name: nil)
        }
        view.machineGone = { [weak host] picked in
            guard let host else { return false }
            return machineGone(picked, listed: host.cloudMachinesListed, in: host.cloudMachineRecords.map(\.id))
        }
        view.name = { [weak host] in host?.chiefDisplayName(conversation) ?? HomeStrings.chiefName }
        view.onUpgrade = { [weak host] in
            // task-owner: one Checkout start; ends when it opens
            Task { await host?.upgradeToPaidPlan() }
        }
        view.onMoveToCloud = { [weak host] in
            // The move runs on the app's Chief; another Chief's page goes to the settings instead.
            guard let host else { return }
            if host.defaultChiefConversation == conversation { host.moveDefaultChiefToCloud() } else { host.showChiefSettings() }
        }
    }

    /// The expanded page's own profile: the shared wiring, its control bar (Take Over / Give Back) and where it runs.
    public static func wirePage(_ view: HomeChiefProfileView, host: any ChiefComputerHost, conversation: String) {
        wire(view, host: host, conversation: conversation)
        let machine = attachedMachine(host, conversation)
        view.control = host.chiefComputerControlSource(agent: machine == nil ? computerKey(host, conversation) : nil, machine: machine)
        view.place = { [weak host] in host?.cloudChiefID(conversation) != nil ? HomeEngineStrings.runsInCloud : HomeEngineStrings.runsHere }
        view.onSettings = { [weak host] in host?.showChiefSettings() }
    }

    /// The settings popover's profile Computer tab (the wiring the expanded page shares) and its Expand.
    /// `popupChanged` runs when the popup over the chat may show or hide; `controlChanged` when the computer it drives may change.
    public static func wirePopover(_ popover: HomeChiefSettingsPopover, host: any ChiefComputerHost, conversation: String,
                                   popupChanged: @escaping () -> Void, controlChanged: @escaping () -> Void) {
        let view = popover.content, profile = popover.profile
        wire(profile, host: host, conversation: conversation)
        // The chat's popup hides while the popover shows the computer, and comes back as it goes.
        profile.onTab = popupChanged
        popover.onClose = popupChanged
        profile.computer.pointerPainter = host.chiefComputerPointerPainter { [weak host] in
            host?.chiefDisplayName(conversation) ?? HomeStrings.chiefName
        }
        profile.onExpand = { [weak host, weak popover] in
            popover?.close()
            // A Cloud machine's Expand is its live desktop, the stream Show Desktop opens.
            guard let host else { return }
            if let machine = attachedMachine(host, conversation) {
                host.openChiefComputerDesktop(machine: machine)
                return
            }
            let arguments: [String: ActionValue] = ["conversation": .string(conversation), "open": .string("1")]
            _ = host.registry.perform(toggleActionID, invocation: ActionInvocation(arguments: arguments, origin: .user))
        }
        let shown = view.onComputerShown
        view.onComputerShown = { [weak view, weak profile, weak host] in
            shown()
            // The Cloud machine picked for a Chief of this Mac is the one its chat preview and Take Over use.
            if let view, let profile, let store = host?.computerControl, store.attachedMachines[conversation] != view.attachedMachine {
                store.attachedMachines[conversation] = view.attachedMachine
                if profile.computer.isOpen { profile.computer.open() }
            }
            controlChanged()
        }
    }

    /// The control bar's computer: a Cloud Chief's own, else the Cloud machine a Chief of this Mac uses, else its own.
    public static func followControl(_ popover: HomeChiefSettingsPopover, popup: HomeChiefComputerPopup?, host: any ChiefComputerHost, conversation: String) {
        let machine = host.cloudChiefID(conversation) == nil ? popover.content.attachedMachine : nil
        let agent = machine == nil ? computerKey(host, conversation) : nil
        popover.profile.follow(agent: agent, machine: machine) { [weak host] in host?.chiefComputerControlSource(agent: $0, machine: $1) }
        popup?.followControl(agent: agent, machine: machine) { [weak host] in host?.chiefComputerControlSource(agent: $0, machine: $1) }
    }

    /// The live view over the chat while the Chief uses its computer. A click runs `open`; `suppressed` hides it.
    public static func makePopup(host: any ChiefComputerHost, conversation: String, suppressed: @escaping () -> Bool,
                                 open: @escaping () -> Void) -> HomeChiefComputerPopup {
        let popup = HomeChiefComputerPopup()
        popup.section.source = source(host: host, conversation: conversation)
        popup.isSuppressed = suppressed
        popup.onOpen = open
        popup.inUse = { [weak host] in
            guard let host, let machine = attachedMachine(host, conversation) else { return false }
            return host.computerControl.isInUse(machine: machine)
        }
        popup.chief = { [weak host] in host?.chiefDisplayName(conversation) ?? HomeStrings.chiefName }
        popup.section.pointerPainter = host.chiefComputerPointerPainter(chief: popup.chief)
        return popup
    }
}
