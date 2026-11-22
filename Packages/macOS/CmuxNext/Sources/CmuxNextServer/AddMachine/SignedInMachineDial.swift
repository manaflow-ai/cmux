import CmuxNextCompat
public import CmuxNextRemote
import CmuxNextWakeups
import Observation

/// One person-proven acpmux line (the app's `AcpmuxPersonLine`): a request's `result`, or nil with the
/// refusal's `error.data.reason` in ``lastErrorReason``.
@MainActor
public protocol JoinedDialLine: AnyObject {
    func call(_ method: String, _ params: [String: Any]) async -> [String: Any]?
    var lastErrorReason: String? { get }
    func close()
}

/// New Workspace on a joined Mac the app reaches only through the hub (cut 1 of the remote plan,
/// hq#11046). Leo, 2026-11-14, to option (a): on the new Mac, one click grants control to "your other
/// Macs signed in to this account"; signing in alone does not count as consent.
///
/// Over one acpmux line: the route acpmux keeps for that Mac (`_acpmux/machine_routes`), then the probe
/// (`_acpmux/machine_route_probe`), which that Mac answers from its person's consent and which records
/// its one ask there (its consent card shows it). Once it allows, the route's socket becomes a server's
/// `unix` route (``ServerReach/signedInMachine(daemonID:socket:name:)``, the app's `ServerReachService`),
/// and the workspace opens on it once its session connects. The page asks again while that Mac's card
/// waits (webviews/src/pages/machines/store.ts); nothing here loops.
@MainActor
public struct SignedInMachineDial {
    /// How long the route's session may take to connect after the probe passed.
    public static let connectLimit: Duration = .seconds(20)

    /// A new line, or nil when no acpmux answers.
    let line: @MainActor () async -> (any JoinedDialLine)?
    /// Shows `reach` as a server for the joined machine `joined` (its id) and connects it; false: not now
    /// (signed out).
    let openRoute: @MainActor (_ reach: ServerReach, _ joined: String) -> Bool
    /// Whether the session of a machine id is connected; nil once there is none.
    let isConnected: @MainActor (_ machineID: String) -> Bool?
    /// New Workspace on a machine id (`workspace.newOnMachine`); false when it did not run.
    let newWorkspace: @MainActor (_ machineID: String) -> Bool

    public init(line: @escaping @MainActor () async -> (any JoinedDialLine)?,
                openRoute: @escaping @MainActor (ServerReach, String) -> Bool,
                isConnected: @escaping @MainActor (String) -> Bool?,
                newWorkspace: @escaping @MainActor (String) -> Bool) {
        self.line = line
        self.openRoute = openRoute
        self.isConnected = isConnected
        self.newWorkspace = newWorkspace
    }

    public func open(_ machine: JoinedMachine) async -> JoinedDialAnswer {
        guard let line = await line() else { return .unavailable("acpmux") }
        defer { line.close() }
        let routes = (await line.call("_acpmux/machine_routes", [:]))?["machines"] as? [[String: Any]] ?? []
        guard let route = machine.route(in: routes), let daemonID = route["daemonId"] as? String else {
            return .unavailable("machine.unlisted")
        }
        guard await line.call("_acpmux/machine_route_probe", ["daemonId": daemonID]) != nil else {
            return JoinedDialAnswer(refusal: line.lastErrorReason)
        }
        guard let socket = route["socket"] as? String,
              let reach = try? ServerReach.signedInMachine(daemonID: daemonID, socket: socket, name: machine.name),
              openRoute(reach, machine.id)
        else { return .unavailable("route.socket") }
        guard await connected(reach.machineID, within: Self.connectLimit) else { return .unavailable("route.connect") }
        return newWorkspace(reach.machineID) ? .opened : .unavailable("workspace")
    }

    /// Whether the session of `machineID` connects within `limit`: event-driven, on its connection state
    /// and one deadline.
    func connected(_ machineID: String, within limit: Duration) async -> Bool {
        let deadline = DialDeadline()
        let timer = DemandTimer(owner: "machines.signed-in-connect")
        timer.schedule(after: limit) { @MainActor in deadline.passed = true }
        defer { timer.cancel() }
        let isConnected = isConnected
        for await state in ObservationStream({ () -> DialWait in
            if deadline.passed { return .gone }
            return isConnected(machineID).map { $0 ? .connected : .pending } ?? .gone
        }) {
            switch state {
            case .connected: return true
            case .gone: return false
            case .pending: continue
            }
        }
        return false
    }
}

/// Where ``SignedInMachineDial/connected(_:within:)`` stands.
nonisolated enum DialWait: Equatable, Sendable { case pending, connected, gone }

/// The connect wait's deadline, observed beside the connection state.
@MainActor @Observable final class DialDeadline {
    var passed = false
}

/// The joined Macs reached through the hub that the person opened a workspace on, in the app's servers
/// (`ServerReachService`): kept across reads of the paired servers until the account changes.
@MainActor
public final class SignedInMachineRoutes {
    /// A server's machine id to the joined machine's id (`JoinedMachine.id`): its Machines row stays that
    /// joined machine's, under Joined (`MachineSectionRow.rows`).
    public private(set) var joinedByMachine: [String: String] = [:]
    private var reaches: [String: ServerReach] = [:]

    public init() {}

    public func record(_ reach: ServerReach, joined: String) {
        reaches[reach.machineID] = reach
        joinedByMachine[reach.machineID] = joined
    }

    /// The account changed: none is kept.
    public func clear() {
        reaches = [:]
        joinedByMachine = [:]
    }

    /// The kept routes `desired` (a read's paired servers) leaves out, which the read must not remove.
    public func kept(beyond desired: [ServerReach]) -> [ServerReach] {
        reaches.values.filter { reach in !desired.contains { $0.machineID == reach.machineID } }
            .sorted { $0.machineID < $1.machineID }
    }
}
