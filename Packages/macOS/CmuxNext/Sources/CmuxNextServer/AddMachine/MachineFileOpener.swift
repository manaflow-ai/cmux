import CmuxNextCompat
import CmuxNextWakeups
import Foundation
import Observation

/// `cmux file open --machine M --path P`: finds machine `M` and a pane of it a window shows, where the app
/// opens `P` in a file page read on `M`. `M` is a connected machine (its id or sidebar name) or an own Mac
/// joined by sign-in (its id, the Machines list's `joined:<id>`, its name or hostname), dialed first the
/// way its Machines row opens it. With no pane of `M` shown, a new workspace on it gives one.
/// Leo: "Own machines as good as Cloud".
@MainActor public struct MachineFileOpener<Pane> {
    /// How long a new workspace's pane may take to show in a window after the daemon made it.
    public static var paneLimit: Duration { .seconds(10) }

    /// Where a `--machine` name leads.
    public nonisolated enum Reach: Equatable, Sendable {
        /// A machine with a session here (its machine id).
        case connected(String)
        /// A joined Mac with no session yet: dial it first.
        case joined(JoinedMachine)
        case unknown
    }

    /// The machines with a session here: machine id and sidebar name.
    let connected: @MainActor () -> [(id: String, name: String?)]
    /// The joined Macs, and a server's machine id to its joined machine's id (`SignedInMachineRoutes`).
    let joined: @MainActor () -> (machines: [JoinedMachine], byMachine: [String: String])
    /// Reads the joined Macs again (one joined since the list last read).
    let refreshJoined: @MainActor () async -> Void
    /// Dials a joined Mac (`SignedInMachineDial.open`) without a new workspace.
    let dial: @MainActor (JoinedMachine) async -> JoinedDialAnswer
    /// A pane of a machine id a window shows (the focused one first), nil when none or no such session.
    let shownPane: @MainActor (String) -> Pane?
    /// New Workspace on a machine id; false when it did not start.
    let newWorkspace: @MainActor (String) async -> Bool

    public init(connected: @escaping @MainActor () -> [(id: String, name: String?)],
                joined: @escaping @MainActor () -> (machines: [JoinedMachine], byMachine: [String: String]),
                refreshJoined: @escaping @MainActor () async -> Void, dial: @escaping @MainActor (JoinedMachine) async -> JoinedDialAnswer,
                shownPane: @escaping @MainActor (String) -> Pane?, newWorkspace: @escaping @MainActor (String) async -> Bool) {
        self.connected = connected
        self.joined = joined
        self.refreshJoined = refreshJoined
        self.dial = dial
        self.shownPane = shownPane
        self.newWorkspace = newWorkspace
    }

    /// The pane of machine `name` to open the page in, or why there is none.
    public func pane(machine name: String) async -> Result<Pane, MachineFileOpenRefusal> {
        var found = Self.reach(name, connected: connected(), joined: joined().machines, joinedByMachine: joined().byMachine)
        if found == .unknown {
            await refreshJoined()
            found = Self.reach(name, connected: connected(), joined: joined().machines, joinedByMachine: joined().byMachine)
        }
        let machineID: String
        switch found {
        case .connected(let id): machineID = id
        case .unknown: return .failure(.noMachine(name))
        case .joined(let machine):
            if let refusal = MachineFileOpenRefusal(answer: await dial(machine), name: name) { return .failure(refusal) }
            guard let id = joined().byMachine.first(where: { $0.value == machine.id })?.key else { return .failure(.unreachable(name)) }
            machineID = id
        }
        if let pane = shownPane(machineID) { return .success(pane) }
        guard await newWorkspace(machineID) else { return .failure(.unreachable(name)) }
        return await shown(machineID, within: Self.paneLimit).map { .success($0) } ?? .failure(.noPane)
    }

    /// A pane of `machineID` once a window shows one, within `limit`: event-driven, on the panes and one deadline.
    func shown(_ machineID: String, within limit: Duration) async -> Pane? {
        let deadline = DialDeadline()
        let timer = DemandTimer(owner: "machines.file-open-pane")
        timer.schedule(after: limit) { @MainActor in deadline.passed = true }
        defer { timer.cancel() }
        let shownPane = shownPane
        for await done in ObservationStream({ () -> Bool in deadline.passed || shownPane(machineID) != nil }) where done { break }
        return shownPane(machineID)
    }

    /// A connected machine whose id or sidebar name is `name`, else a joined Mac named so (any case), reached
    /// through its session when one is open (`joinedByMachine`: a server's machine id to the joined machine's id).
    public nonisolated static func reach(_ name: String, connected: [(id: String, name: String?)], joined: [JoinedMachine],
                                         joinedByMachine: [String: String]) -> Reach {
        let wanted = name.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return .unknown }
        let folded = wanted.lowercased()
        if let hit = connected.first(where: { $0.id == wanted }) ?? connected.first(where: { $0.name?.lowercased() == folded }) {
            return .connected(hit.id)
        }
        let bare = wanted.hasPrefix("joined:") ? String(wanted.dropFirst("joined:".count)) : wanted
        guard let machine = joined.first(where: { $0.id == bare })
            ?? joined.first(where: { $0.name.lowercased() == folded || $0.hostname?.lowercased() == folded })
        else { return .unknown }
        return connected.first { joinedByMachine[$0.id] == machine.id }.map { .connected($0.id) } ?? .joined(machine)
    }
}

/// Why ``MachineFileOpener`` found no pane; ``message`` is the person's words.
public nonisolated enum MachineFileOpenRefusal: Error, Equatable, Sendable {
    case noMachine(String)
    case unreachable(String)
    case consent(String)
    case noPane

    /// The refusal of a dial that did not open, nil when it opened.
    init?(answer: JoinedDialAnswer, name: String) {
        switch answer {
        case .opened: return nil
        case .consentRequired, .consentDeclined: self = .consent(name)
        case .unavailable: self = .unreachable(name)
        }
    }

    /// Nil for ``noPane``: the caller's own words for it.
    public var message: String? {
        switch self {
        case .noMachine(let name): String(format: Self.s("machineFileOpen.noMachine", "No machine is named “%@”."), name)
        case .unreachable(let name): String(format: Self.s("machineFileOpen.unreachable", "%@ can’t be reached right now."), name)
        case .consent(let name): String(format: Self.s("machineFileOpen.consent", "Allow this Mac on %@ first."), name)
        case .noPane: nil
        }
    }

    private static func s(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "AddMachine", bundle: .localizedModule)
    }
}
