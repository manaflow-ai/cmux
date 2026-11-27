public import CMUXAuthCore
public import CmuxNextDaemon
public import Foundation
import CmuxNextWakeups

/// The Cloud machine event socket. `/v1/wire/cloud` carries ephemeral VM events; the bundled `cmux` mints its
/// one-use ticket and opens it (`cmux cloud wire-watch`, cmux-tui `cli/cloud_wire_watch.rs`), the access token on its
/// stdin, never in argv or the subprotocol. Swift decodes the frame lines; reconnects back off after failure.
@MainActor
public final class CloudMachineWire {
    private let apiBaseURL: URL
    private let token: @Sendable () async throws -> String
    private let team: @Sendable () async -> String?
    /// A tagged dev build's cloud data space, on the ticket request and the socket's upgrade; none for nightly; a misconfigured dev build opens none.
    private let buildSpace: CMUXBuildSpaceState
    /// The bundled `cmux` that runs one connection (``CloudCLICall/lines(timeout:)``).
    private let lines: CloudCLICall.Lines
    private var runner: Task<Void, Never>?
    private var generation = 0
    /// The person's spare that the platform says just became ready (`cloud.spare.ready`, for this socket's own team):
    /// its machine id, for the login copy before any claim (Rust's `spare_warm` `ready` coalesces repeats).
    public var onSpareReady: @MainActor (String) -> Void = { _ in }
    /// A machine of this socket's team the platform is about to pause (`cloud.machine.pausing`, sent before the provider
    /// pause): the app parks its link now, so its heartbeat does not redial (and wake) the VM before a list shows the pause.
    /// It may repeat for one pause (each pause attempt sends it); handling it twice is harmless.
    public var onMachinePausing: @MainActor (String) -> Void = { _ in }
    /// The teams the wire subscribes in for an active team (Rust's `wireTeams`): the active one first, then the
    /// install token's team when it is another, where the person's spares live (#36037). Nil: the active team alone.
    public var teams: (@MainActor (String?) async -> [String]?)?

    public init(apiBaseURL: URL, token: @escaping @Sendable () async throws -> String,
                team: @escaping @Sendable () async -> String?, buildSpace: CMUXBuildSpaceState, lines: @escaping CloudCLICall.Lines) {
        (self.apiBaseURL, self.token, self.team, self.buildSpace, self.lines) = (apiBaseURL, token, team, buildSpace, lines)
    }

    /// `teams` and `onSpareReady`: as ``teams`` and ``onSpareReady``, set from the start.
    public convenience init(apiBaseURL: URL, auth: CloudAuth, cli: BundledExecutable, teams: (@MainActor (String?) async -> [String]?)?,
                            onSpareReady: @escaping @MainActor (String) -> Void) {
        self.init(apiBaseURL: apiBaseURL, token: { try await auth.tokens().access }, team: { await auth.teamID },
                  buildSpace: auth.configuration.buildSpace, lines: CloudCLICall(cli: cli).lines(timeout: .seconds(6 * 3600)))
        (self.teams, self.onSpareReady) = (teams, onSpareReady)
    }

    /// The socket of the active team (every event, as before) and, in addition, one socket per other team of
    /// ``extraTeams(active:named:)`` that hears only its spares' readiness (`cloud.spare.ready`, `spares_needing_login`).
    public func start(_ sink: @escaping @MainActor (CloudPortChange) -> Void) {
        stop()
        let generation = generation
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
    }

    /// One socket's reconnect loop: the active team's (`only` nil, read again per connection) or `only`'s, whose
    /// socket has no `sink` (its port changes stay with the active team's socket, as before).
    private func run(_ generation: Int, only: String?, sink: (@MainActor (CloudPortChange) -> Void)?) async {
        var backoff = Backoff(initial: .milliseconds(500), maximum: .seconds(30))
        // wakeup-allow: one pass per connection; each pass awaits the socket and, after a failure, a Backoff delay.
        while !Task.isCancelled, generation == self.generation {
            do {
                try await session(generation, only: only, sink: sink, onSubscribed: { backoff.reset() })
            } catch is CancellationError {
                return
            } catch {}
            // concurrency-allow: Backoff.wait is an async sleep after a failure, not a blocking wait.
            do { try await backoff.wait(owner: "cloud.machine.wire.reconnect") } catch { return }
        }
    }

    private func session(_ generation: Int, only: String?, sink: (@MainActor (CloudPortChange) -> Void)?,
                         onSubscribed: () -> Void) async throws {
        let selectedTeam = if let only { only } else { await team() }
        let stdin = try JSONSerialization.data(withJSONObject: ["api": apiBaseURL.absoluteString, "access": try await token(), "team": selectedTeam,
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String].compactMapValues { $0 })
        _ = try buildSpace.headers() // a misconfigured dev build mints no ticket and opens no socket
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_BUILD_SPACE"] = buildSpace.childEnvironmentValue
        let (frames, continuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingNewest(256)) // the main actor drains each line as it comes
        async let child: Void = Self.run(lines, stdin: stdin, environment: environment, into: continuation)
        // wakeup-allow: each turn awaits the next frame line of the child; its exit ends the stream and the loop.
        for await data in frames {
            guard generation == self.generation else { throw CancellationError() }
            switch Self.frameType(data) {
            case "snapshot":
                onSubscribed()
                // The spares the platform says still need the login (at subscribe and after each recheck): the same copy as the event, coalesced per spare.
                for machine in Self.sparesNeedingLogin(data, team: selectedTeam) { onSpareReady(machine) }
            case "ephemeral":
                if let machine = Self.spareReady(data, team: selectedTeam) { onSpareReady(machine) }
                else if let machine = Self.machinePausing(data, team: selectedTeam) { onMachinePausing(machine) }
                else if let sink, let change = CloudPortChange.parseWireFrame(data) { sink(change) }
            default:
                break
            }
        }
        await child
        try Task.checkCancellation()
        throw CloudAPIError.transport("Cloud wire closed")
    }

    /// One `cmux cloud wire-watch` child: each stdout line into `continuation`, finished when the child exits.
    nonisolated private static func run(_ lines: CloudCLICall.Lines, stdin: Data, environment: [String: String],
                                        into continuation: AsyncStream<Data>.Continuation) async {
        await lines(["cloud", "wire-watch"], stdin, environment) { continuation.yield($0) }
        continuation.finish()
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
