import CmuxEgress
public import CMUXAuthCore
public import Foundation
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextWakeups
#if canImport(Network)
import Network
#endif

/// The Cloud machine event socket. `/v1/wire/cloud` carries ephemeral VM events;
/// the access token is used only to mint a one-use ticket and never goes into the
/// WebSocket subprotocol. Reconnects are event driven and back off after failure.
///
/// The network decides too, as on the iPhone link (cmux-next-ios LinkMachine): when this Mac's path changes and is
/// usable (Wi-Fi back, another network, a VPN), a socket waiting out its backoff dials at once, and a live one sends
/// a ping that must answer within ``networkProbe`` or is dropped and redialed. Before, a socket that died with the
/// old network waited up to 30 s of backoff, and one riding a dead route waited for TCP to give up.
/// Leo, 2026-11-25: "I feel like iOS doesn't retry connections aggressively enough. Or like it isn't detecting when
/// Wi-Fi is restored and all of that ... I mean likewise with all of our other connectivity things."
@MainActor
public final class CloudMachineWire {
    private let apiBaseURL: URL
    private let token: @Sendable () async throws -> String
    private let team: @Sendable () async -> String?
    /// A tagged dev build's cloud data space, on the ticket request and the socket's upgrade; none for nightly; a misconfigured dev build opens none.
    private let buildSpace: CMUXBuildSpaceState
    private var runner: Task<Void, Never>?
    private var generation = 0
    /// Each socket loop's wake (its backoff wait ends on a network change) and its live socket's probe, by loop.
    private var wakes: [Int: RetryWake] = [:]
    private var probes: [Int: @Sendable () -> Void] = [:]
    private var nextLoop = 0
    #if canImport(Network)
    private var pathMonitor: NWPathMonitor?
    #endif
    /// How long a ping sent because the network changed may take to answer before the socket is redialed (the
    /// machine link's and acpmux peers' bound too).
    nonisolated static let networkProbe: Duration = .seconds(2)
    /// The person's spare that the platform says just became ready (`cloud.spare.ready`, for this socket's own team):
    /// its machine id, for the login copy before any claim (Rust's `spare_warm` `ready` coalesces repeats).
    public var onSpareReady: @MainActor (String) -> Void = { _ in }
    /// A machine of this socket's team the platform is about to pause (`cloud.machine.pausing`, sent before the provider
    /// pause): the app parks its link now, so its heartbeat does not redial (and wake) the VM before a list shows the pause.
    /// It may repeat for one pause (each pause attempt sends it); handling it twice is harmless.
    public var onMachinePausing: @MainActor (String) -> Void = { _ in }
    /// An AutoSize notice (`cloud.machine.autosize`, RFD 0080 piece 4) on the active team's socket: the frame as it came
    /// and the socket's team, for Rust's AutoSize feed (`cloud_autosize_frame`), which reads and checks it.
    public var onAutoSizeFrame: @MainActor (Data, String?) -> Void = { _, _ in }
    /// The teams the wire subscribes in for an active team (Rust's `wireTeams`): the active one first, then the
    /// install token's team when it is another, where the person's spares live (#36037). Nil: the active team alone.
    public var teams: (@MainActor (String?) async -> [String]?)?

    public init(apiBaseURL: URL, token: @escaping @Sendable () async throws -> String,
                team: @escaping @Sendable () async -> String?, buildSpace: CMUXBuildSpaceState) {
        self.apiBaseURL = apiBaseURL
        self.token = token
        self.team = team
        self.buildSpace = buildSpace
    }

    /// `teams` and `onSpareReady`: as ``teams`` and ``onSpareReady``, set from the start.
    public convenience init(apiBaseURL: URL, auth: CloudAuth, teams: (@MainActor (String?) async -> [String]?)?,
                            onSpareReady: @escaping @MainActor (String) -> Void) {
        self.init(apiBaseURL: apiBaseURL, token: { try await auth.tokens().access },
                  team: { await auth.teamID }, buildSpace: auth.configuration.buildSpace)
        (self.teams, self.onSpareReady) = (teams, onSpareReady)
    }

    /// The socket of the active team (every event, as before) and, in addition, one socket per other team of
    /// ``extraTeams(active:named:)`` that hears only its spares' readiness (`cloud.spare.ready`, `spares_needing_login`).
    public func start(_ sink: @escaping @MainActor (CloudPortChange) -> Void) {
        stop()
        let generation = generation
        watchNetwork()
        runner = Task { [weak self] in
            guard let self else { return }
            let active = await self.team()
            let extra = Self.extraTeams(active: active, named: await self.teams?(active))
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in await self?.run(generation, only: nil, sink: sink) }
                for team in extra {
                    group.addTask { [weak self] in await self?.run(generation, only: team, sink: nil) }
                }
            }
        }
    }

    /// The teams past the active one that Rust named, never the active one again: none when they are the same.
    nonisolated static func extraTeams(active: String?, named: [String]?) -> [String] {
        guard let active, !active.isEmpty else { return [] }
        var seen: Set<String> = [active]
        return (named ?? []).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    public func stop() {
        generation += 1
        runner?.cancel()
        runner = nil
        #if canImport(Network)
        pathMonitor?.cancel()
        pathMonitor = nil
        #endif
    }

    /// This Mac's network changed and is usable: every loop waiting out its backoff dials now, every live socket is
    /// probed (a change that comes while a dial runs is kept and ends the next wait at once).
    func networkChanged() {
        for wake in wakes.values { wake.fire() }
        for probe in probes.values { probe() }
    }

    private func watchNetwork() {
        #if canImport(Network)
        let monitor = NWPathMonitor()
        // The first update reports the path as it is at start: no change, so no wake.
        let reported = Mutex(false)
        monitor.pathUpdateHandler = { [weak self] path in
            let first = reported.withLock { seen in
                defer { seen = true }
                return !seen
            }
            guard !first, path.status == .satisfied else { return }
            // task-owner: one hop to the main actor per path change
            Task { @MainActor [weak self] in self?.networkChanged() }
        }
        monitor.start(queue: DispatchQueue(label: "com.cmuxterm.next.cloud.wire.path", qos: .utility))
        pathMonitor = monitor
        #endif
    }

    /// One socket's reconnect loop: the active team's (`only` nil, read again per connection) or `only`'s, whose
    /// socket has no `sink` (its port changes stay with the active team's socket, as before).
    private func run(_ generation: Int, only: String?, sink: (@MainActor (CloudPortChange) -> Void)?) async {
        let loop = nextLoop
        nextLoop += 1
        let wake = RetryWake(owner: "cloud.machine.wire.reconnect")
        wakes[loop] = wake
        defer { wakes[loop] = nil; probes[loop] = nil }
        await Self.reconnecting(wake: wake, backoff: Backoff(initial: .milliseconds(500), maximum: .seconds(30)),
                                keepGoing: { [weak self] in generation == self?.generation }) { [weak self] onSubscribed in
            guard let self else { throw CancellationError() }
            try await self.session(generation, loop: loop, only: only, sink: sink, onSubscribed: onSubscribed)
        }
    }

    /// One socket's reconnect loop: `session` runs a connection to its end (it calls its argument once subscribed,
    /// which starts the backoff over), then the loop waits the backoff's next step or, sooner, a network change on
    /// `wake`, which also starts the backoff over. Ends when the task is cancelled, `session` throws
    /// `CancellationError` or `keepGoing` says no.
    static func reconnecting(wake: RetryWake, backoff: Backoff, clock: any Clock<Duration> = ContinuousClock(),
                             keepGoing: () -> Bool,
                             session: (_ onSubscribed: () -> Void) async throws -> Void) async {
        var backoff = backoff
        // wakeup-allow: one pass per connection; each pass awaits the socket and, after a failure, a Backoff delay or a network change.
        while !Task.isCancelled, keepGoing() {
            do {
                try await session { backoff.reset() }
            } catch is CancellationError {
                return
            } catch {}
            guard !Task.isCancelled, keepGoing() else { return }
            switch await wake.awaitWake(delay: backoff.next(), clock: clock, socket: false) {
            case .cancelled: return
            case .event: backoff.reset()
            case .socket, .timer: break
            }
        }
    }

    private func session(_ generation: Int, loop: Int, only: String?, sink: (@MainActor (CloudPortChange) -> Void)?,
                         onSubscribed: () -> Void) async throws {
        let selectedTeam = if let only { only } else { await team() }
        let access = try await token()
        let ticket = try await mintTicket(access: access)
        let request = try Self.socketRequest(apiBaseURL: apiBaseURL, ticket: ticket, team: selectedTeam,
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, buildSpace: buildSpace)
        let task = CmuxEgress.websocket(CmuxEgress.shared(site: "CmuxNextCloud.CloudMachineWire"), with: request, site: "CmuxNextCloud.CloudMachineWire")
        task.maximumMessageSize = 8 << 20
        task.resume()
        probes[loop] = Self.probe(task)
        defer { probes[loop] = nil; task.cancel(with: .goingAway, reason: nil) }
        try await withTaskCancellationHandler {
            // wakeup-allow: each turn awaits the next frame; a closed socket throws and ends the loop.
            while !Task.isCancelled {
                let message = try await task.receive()
                let data: Data
                switch message {
                case let .string(text): data = Data(text.utf8)
                case let .data(bytes): data = bytes
                @unknown default: continue
                }
                guard generation == self.generation else { throw CancellationError() }
                guard let type = Self.frameType(data) else { continue }
                switch type {
                case "welcome":
                    try await task.send(.string(#"{"t":"subscribe"}"#))
                case "snapshot":
                    onSubscribed()
                    // The spares the platform says still need the login (at subscribe and after each recheck): the same copy as the event, coalesced per spare.
                    for machine in Self.sparesNeedingLogin(data, team: selectedTeam) { onSpareReady(machine) }
                case "ephemeral":
                    if let machine = Self.spareReady(data, team: selectedTeam) { onSpareReady(machine) }
                    else if let machine = Self.machinePausing(data, team: selectedTeam) { onMachinePausing(machine) }
                    else if sink != nil, Self.isAutoSize(data) { onAutoSizeFrame(data, selectedTeam) }
                    else if let sink, let change = CloudPortChange.parseWireFrame(data) { sink(change) }
                default:
                    break
                }
            }
            throw CancellationError()
        } onCancel: {
            task.cancel(with: .goingAway, reason: nil)
        }
    }

    /// A ping on `task` that must answer within ``networkProbe``, else the socket is cancelled (its receive throws and
    /// the loop redials at once: the change that sent the probe is still pending on its wake).
    nonisolated static func probe(_ task: URLSessionWebSocketTask) -> @Sendable () -> Void {
        { [weak task] in
            guard let task else { return }
            let deadline = DemandTimer(owner: "cloud.machine.wire.probe")
            deadline.schedule(after: networkProbe) { [weak task] in
                task?.cancel(with: .goingAway, reason: nil)
            }
            task.sendPing { [weak task] error in
                deadline.cancel()
                if error != nil { task?.cancel(with: .goingAway, reason: nil) }
            }
        }
    }

    /// The `/v1/wire/cloud` socket's upgrade: the one-use ticket and the team in the subprotocol, the app version and
    /// the build space, when there is one.
    nonisolated static func socketRequest(apiBaseURL: URL, ticket: String, team: String?, version: String?,
                                          buildSpace: CMUXBuildSpaceState) throws -> URLRequest {
        var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.path = "/v1/wire/cloud"
        guard let url = components.url else { throw CloudAPIError.transport("invalid Cloud wire URL") }
        var request = URLRequest(url: url)
        let teamProtocol = team.flatMap { $0.isEmpty ? nil : "team.\($0)" }
        request.setValue(([
            "cmux.wire.v1", "ticket.\(ticket)", teamProtocol,
        ].compactMap { $0 }).joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol")
        if let version { request.setValue(version, forHTTPHeaderField: "x-cmux-client-version") }
        try buildSpace.apply(to: &request)
        return request
    }

    /// `POST /v1/wire/ticket` for the cloud scope, with the person's session and the build space, when there is one.
    nonisolated static func ticketRequest(apiBaseURL: URL, access: String, buildSpace: CMUXBuildSpaceState) throws -> URLRequest {
        var request = URLRequest(url: apiBaseURL.appendingPathComponent("v1/wire/ticket"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"scope":"cloud"}"#.utf8)
        try buildSpace.apply(to: &request)
        return request
    }

    private func mintTicket(access: String) async throws -> String {
        let request = try Self.ticketRequest(apiBaseURL: apiBaseURL, access: access, buildSpace: buildSpace)
        let (data, response) = try await CmuxEgress.shared(site: "CmuxNextCloud.CloudMachineWire").data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CloudAPIError.transport("Cloud wire ticket refused")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let ticket = object["ticket"] as? String, !ticket.isEmpty else {
            throw CloudAPIError.decoding("Cloud wire ticket response")
        }
        return ticket
    }

    /// The spares a `snapshot` of this socket's own team (`cloud:<team>`) names in `spares_needing_login`: the person's
    /// ready spares with no login reported yet (ids only). Empty for any other frame or team.
    nonisolated static func sparesNeedingLogin(_ frame: Data, team: String?) -> [String] {
        guard let team, let object = (try? JSONSerialization.jsonObject(with: frame)) as? [String: Any],
              object["t"] as? String == "snapshot", object["stream"] as? String == "cloud:\(team)",
              let ids = object["spares_needing_login"] as? [Any] else { return [] }
        return ids.compactMap { ($0 as? String).flatMap { $0.hasPrefix("vm_") ? $0 : nil } }
    }

    /// The machine of a `cloud.spare.ready` frame for `team`, the team this socket was opened in; nil for any other frame.
    nonisolated static func spareReady(_ frame: Data, team: String?) -> String? {
        guard let team, let object = (try? JSONSerialization.jsonObject(with: frame)) as? [String: Any],
              object["event"] as? String == "cloud.spare.ready", let data = object["data"] as? [String: Any],
              data["team"] as? String == team, let machine = data["machine"] as? String, !machine.isEmpty else { return nil }
        return machine
    }

    /// The machine of a `cloud.machine.pausing` frame for `team`, the team this socket was opened in; nil for any other frame.
    nonisolated static func machinePausing(_ frame: Data, team: String?) -> String? {
        guard let team, let object = (try? JSONSerialization.jsonObject(with: frame)) as? [String: Any],
              object["t"] as? String == "ephemeral", object["event"] as? String == "cloud.machine.pausing",
              let data = object["data"] as? [String: Any], data["team"] as? String == team,
              let machine = data["machine"] as? String, machine.hasPrefix("vm_") else { return nil }
        return machine
    }

    /// Whether `frame` names the `cloud.machine.autosize` event; Rust reads the rest.
    nonisolated static func isAutoSize(_ frame: Data) -> Bool {
        ((try? JSONSerialization.jsonObject(with: frame)) as? [String: Any])?["event"] as? String == "cloud.machine.autosize"
    }

    /// Sets ``onAutoSizeFrame`` (for a lazily built wire) and returns the wire.
    @discardableResult
    public func onAutoSize(_ handler: @escaping @MainActor (Data, String?) -> Void) -> Self {
        onAutoSizeFrame = handler
        return self
    }

    /// Sets ``onMachinePausing`` (for a lazily built wire) and returns the wire.
    @discardableResult
    public func onPausing(_ handler: @escaping @MainActor (String) -> Void) -> Self {
        onMachinePausing = handler
        return self
    }

    private nonisolated static func frameType(_ data: Data) -> String? {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["t"] as? String
    }
}
