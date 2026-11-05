public import CmuxNextDaemon
public import Foundation

/// The pushed connection state of the Cloud machines the app shows (Leo, 2026-11-05: "yes" to a per-machine
/// state object so the app stops polling). One WebSocket per machine, `GET /v1/cloud/machines/{id}/state` on the
/// platform Worker (cmux-platform `MachineState`, protocol `cmux.machine-state/1`), with the person's Stack access
/// token and the cmux team, like the relay chat. Each text frame (`{v, t: state|removed, machine, revision, state?}`)
/// goes as it came to the Cloud app server (`apps-team-event` on ``connection``), which applies it to its machine
/// projection and wakes an op waiting on that machine; the record it carries goes to ``onRecord`` (a removal as the
/// last record with status destroyed), which the app shows like a read's answer.
///
/// A socket that closes (the platform ends one at its token's expiry, an hour at most, or the network dropped) is
/// opened again with a fresh token after a capped backoff: that is a reconnect, not a poll. Nothing here logs a
/// token or a frame.
@MainActor
public final class CloudMachineStatePush {
    let baseURL: URL
    let accessToken: @Sendable () async throws -> String
    let teamID: CloudAPIClient.TeamID
    let session: URLSession
    /// The local daemon's connection the frames go to (the Cloud app server's host).
    public var connection: @MainActor () -> DaemonConnection? = { nil }
    /// A machine's record from its push.
    public var onRecord: @MainActor (CloudMachine) -> Void = { _ in }
    /// A machine's live push closed: until a socket delivers again it is not pushed, and reads cover it.
    public var onLost: @MainActor (String) -> Void = { _ in }
    /// A machine's push became live (a frame reached the Cloud app server): its reads are no longer needed.
    public var onLive: @MainActor (String) -> Void = { _ in }
    private var last: [String: CloudMachine] = [:]
    /// Raised by ``stop()``: a frame received before it is never sent to the daemon after it.
    private var generation = 0
    /// The frames on their way to the daemon, one after another, in the order they came.
    private var delivery: Task<Void, Never>?

    private struct Watch {
        var task: URLSessionWebSocketTask?
        var runner: Task<Void, Never>?
        /// A frame of the open socket reached the Cloud app server: pushes are live for this machine. A failed hand-off
        /// clears it until the next frame gets through.
        var live = false
        /// The open socket's id (``nextSocket``): a hand-off that finishes after its socket closed changes nothing.
        var socket = 0
    }
    private var watches: [String: Watch] = [:]
    /// The last socket id handed out. It only grows, across every machine and every recreated watch, so a hand-off
    /// queued on an old socket can never match a new one.
    private var lastSocket = 0

    /// The first reconnect waits this long; each failure doubles it up to ``maxBackoff``.
    static let firstBackoff: Duration = .milliseconds(500)
    static let maxBackoff: Duration = .seconds(30)
    /// An open socket sends the protocol's `ping` this often, so no proxy closes it for being quiet; the platform's
    /// runtime answers `pong` without waking the object.
    static let keepalive: Duration = .seconds(30)

    /// `session` must refuse redirects (``CloudOwnerAPIClient/transport`` does): one would carry the bearer elsewhere.
    public init(baseURL: URL, accessToken: @escaping @Sendable () async throws -> String, teamID: @escaping CloudAPIClient.TeamID,
                session: URLSession? = nil) {
        (self.baseURL, self.accessToken, self.teamID) = (baseURL, accessToken, teamID)
        self.session = session ?? CloudOwnerAPIClient.transport
    }

    /// Whether `machine`'s state is pushed now (its socket is open and its last frame reached the Cloud app server).
    public func isLive(_ machine: String) -> Bool { watches[machine]?.live == true }

    /// Watches exactly `machines` (a list's records): opens a socket for each new one and closes the ones no longer
    /// shown. A listed record is the last one known until a frame brings a newer one, so a removal that comes as the
    /// socket's first frame still shows.
    public func watch(_ machines: [CloudMachine]) {
        let shown = Set(machines.map(\.id))
        for id in Array(watches.keys) where !shown.contains(id) { end(id) }
        for machine in machines where Self.validID(machine.id) {
            let id = machine.id
            if last[id].map({ !CloudMachineChanges.newerRevision($0.serverRevision, than: machine.serverRevision) }) ?? true {
                last[id] = machine
            }
            guard watches[id] == nil else { continue }
            watches[id] = Watch()
            watches[id]?.runner = Task { [weak self] in await self?.run(id) }
        }
    }

    /// Closes every socket (sign-out, a team switch, Cloud turned off).
    public func stop() {
        generation += 1
        delivery?.cancel()
        delivery = nil
        for id in Array(watches.keys) { end(id) }
    }

    private func end(_ id: String) {
        last[id] = nil
        guard let watch = watches.removeValue(forKey: id) else { return }
        watch.runner?.cancel()
        watch.task?.cancel(with: .normalClosure, reason: nil)
    }

    static func validID(_ id: String) -> Bool {
        id.hasPrefix("vm_") && id.count == 23 && id.dropFirst(3).allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber) }
    }

    func url(_ machine: String) -> URL? {
        guard var parts = URLComponents(url: baseURL.appendingPathComponent("v1/cloud/machines/\(machine)/state"),
                                        resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = parts.scheme == "http" ? "ws" : "wss"
        return parts.url
    }

    private func run(_ machine: String) async {
        var backoff = Self.firstBackoff
        // wakeup-allow: one pass per socket, each awaiting the socket's life and then a capped backoff; ends when unwatched
        while !Task.isCancelled, watches[machine] != nil {
            let opened = await connect(machine)
            if Task.isCancelled || watches[machine] == nil { return }
            let wasLive = watches[machine]?.live == true
            watches[machine]?.live = false
            watches[machine]?.task = nil
            // Pushes stopped: the machine's reads come back until a socket delivers again.
            if wasLive { onLost(machine) }
            // A socket that delivered frames closed (a token expiry, a deploy): the next waits the first backoff;
            // one that never delivered doubles it. Every close waits, so a socket that opens and closes cannot spin.
            if opened { backoff = Self.firstBackoff }
            // wakeup-allow: capped reconnect backoff of a closed push socket, cancelled when the machine is no longer shown
            do { try await ContinuousClock().sleep(for: backoff) } catch { return }
            backoff = min(backoff * 2, Self.maxBackoff)
        }
    }

    /// One socket's life; true when it delivered at least one frame.
    private func connect(_ machine: String) async -> Bool {
        guard let url = url(machine), let token = try? await accessToken() else { return false }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        if let team = await teamID() { request.setValue(team, forHTTPHeaderField: "x-cmux-team") }
        guard watches[machine] != nil, !Task.isCancelled else { return false }
        let task = session.webSocketTask(with: request)
        watches[machine]?.task = task
        watches[machine]?.socket = nextSocket()
        task.resume()
        let ping = Task {
            // wakeup-allow: one keepalive send per open push socket every 30 s, ended with the socket
            while (try? await ContinuousClock().sleep(for: Self.keepalive)) != nil {
                guard (try? await task.send(.string(#"{"v":1,"t":"ping"}"#))) != nil else { return }
            }
        }
        defer { ping.cancel() }
        var delivered = false
        // wakeup-allow: each pass awaits the next frame; a closed or failed socket throws and ends the loop
        while !Task.isCancelled, let message = try? await task.receive() {
            let data: Data
            switch message {
            case .string(let text): data = Data(text.utf8)
            case .data(let bytes): data = bytes
            @unknown default: data = Data()
            }
            delivered = true
            received(machine, data)
        }
        task.cancel(with: .normalClosure, reason: nil)
        return delivered
    }

    /// One frame: to the app server first (so an op waiting on the machine runs as the record shows), then its record.
    func received(_ machine: String, _ frame: Data) {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: frame), value["machine"]?.stringValue == machine
        else { return }
        switch value["t"]?.stringValue {
        case "state":
            guard let record = value["state"]?["record"], let shown = CloudMachine(next: record) else { return }
            // A record older than one already shown (a read that answered first) is not shown again.
            if let known = last[machine], CloudMachineChanges.newerRevision(known.serverRevision, than: shown.serverRevision) {
                return
            }
            forward(machine, value)
            last[machine] = shown
            onRecord(shown)
        case "removed":
            forward(machine, value)
            let gone = last[machine]
            // The machine is gone for good: its socket closes now, not at the next list.
            end(machine)
            guard var gone else { return }
            gone.status = .destroyed
            onRecord(gone)
        default:
            return
        }
    }

    /// Sends one frame to the Cloud app server after the frames before it, unless ``stop()`` came first. A frame that
    /// gets there makes the machine live; one that does not (no daemon connection, a refused request) takes it off, so
    /// its reads come back until a later frame gets through.
    private func forward(_ machine: String, _ value: JSONValue) {
        let connection = connection(), previous = delivery, sent = generation, socket = watches[machine]?.socket
        // task-owner: kept in `delivery` and cancelled by stop()
        delivery = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled, self?.generation == sent else { return }
            let ok: Bool
            if let connection {
                ok = Self.handedOff(try? await connection.request(AppsTeamEventRequest(event: "cloud.machine.state", data: value)))
            } else {
                ok = false
            }
            guard !Task.isCancelled, let self, self.generation == sent else { return }
            self.delivered(machine, socket: socket, ok)
        }
    }

    /// A new socket id, larger than every one before it.
    func nextSocket() -> Int {
        lastSocket += 1
        return lastSocket
    }

    /// Whether `apps-team-event` answered that a Cloud app server took the frame (`{servers: N}`, N > 0). A reply
    /// with no server (none running, or none holding the Cloud scope) is not a hand-off: the machine stays on reads.
    static func handedOff(_ reply: JSONValue?) -> Bool {
        guard let servers = reply?["servers"]?.doubleValue else { return false }
        return servers > 0
    }

    private func delivered(_ machine: String, socket: Int?, _ ok: Bool) {
        // Only the socket the frame came on, still open: one that closed already handed its machine back to reads.
        guard let watch = watches[machine], watch.task != nil, watch.socket == socket, watch.live != ok else { return }
        watches[machine]?.live = ok
        if ok { onLive(machine) } else { onLost(machine) }
    }
}

extension CloudAPIClient {
    /// The machine state sockets at `baseURL` (``CloudConfiguration/relayAPIBaseURL(environment:)``, the platform
    /// origin), as this client's person and team; nil for the classic client, whose Stack session the platform does
    /// not take (as ``relayChat(baseURL:)``).
    @MainActor
    public func statePush(baseURL: URL) -> CloudMachineStatePush? {
        guard !sendsStackSession else { return nil }
        let tokens = tokens
        return CloudMachineStatePush(baseURL: baseURL, accessToken: { try await tokens().0 }, teamID: teamID)
    }
}
