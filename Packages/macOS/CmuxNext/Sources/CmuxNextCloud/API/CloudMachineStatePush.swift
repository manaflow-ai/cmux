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
    private var last: [String: CloudMachine] = [:]

    private struct Watch {
        var task: URLSessionWebSocketTask?
        var runner: Task<Void, Never>?
        /// A frame came on the open socket: pushes are live for this machine.
        var live = false
    }
    private var watches: [String: Watch] = [:]

    /// The first reconnect waits this long; each failure doubles it up to ``maxBackoff``.
    static let firstBackoff: Duration = .milliseconds(500)
    static let maxBackoff: Duration = .seconds(30)

    /// `session` must refuse redirects (``CloudOwnerAPIClient/transport`` does): one would carry the bearer elsewhere.
    public init(baseURL: URL, accessToken: @escaping @Sendable () async throws -> String, teamID: @escaping CloudAPIClient.TeamID,
                session: URLSession? = nil) {
        (self.baseURL, self.accessToken, self.teamID) = (baseURL, accessToken, teamID)
        self.session = session ?? CloudOwnerAPIClient.transport
    }

    /// Whether `machine`'s state is pushed now (its socket is open and sent its first frame).
    public func isLive(_ machine: String) -> Bool { watches[machine]?.live == true }

    /// Watches exactly `machines` (a list's records): opens a socket for each new one and closes the ones no longer
    /// shown. A listed record is the last one known until a frame brings a newer one, so a removal that comes as the
    /// socket's first frame still shows.
    public func watch(_ machines: [CloudMachine]) {
        let shown = Set(machines.map(\.id))
        for id in Array(watches.keys) where !shown.contains(id) { end(id) }
        for machine in machines where Self.validID(machine.id) {
            let id = machine.id
            if last[id] == nil { last[id] = machine }
            guard watches[id] == nil else { continue }
            watches[id] = Watch()
            watches[id]?.runner = Task { [weak self] in await self?.run(id) }
        }
    }

    /// Closes every socket (sign-out, a team switch, Cloud turned off).
    public func stop() {
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
        while !Task.isCancelled, watches[machine] != nil {
            let opened = await connect(machine)
            if Task.isCancelled || watches[machine] == nil { return }
            watches[machine]?.live = false
            watches[machine]?.task = nil
            // A socket that delivered frames closed (a token expiry, a deploy): open the next one at once.
            if opened { backoff = Self.firstBackoff; continue }
            // wakeup-allow: capped reconnect backoff of a closed push socket, cancelled when the machine is no longer shown
            try? await ContinuousClock().sleep(for: backoff)
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
        task.resume()
        var delivered = false
        while !Task.isCancelled {
            guard let message = try? await task.receive() else { break }
            let data: Data
            switch message {
            case .string(let text): data = Data(text.utf8)
            case .data(let bytes): data = bytes
            @unknown default: continue
            }
            delivered = true
            watches[machine]?.live = true
            received(machine, data)
        }
        task.cancel(with: .normalClosure, reason: nil)
        return delivered
    }

    /// One frame: to the app server first (so an op waiting on the machine runs as the record shows), then its record.
    func received(_ machine: String, _ frame: Data) {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: frame), value["machine"]?.stringValue == machine
        else { return }
        let connection = connection()
        // task-owner: one hop to the daemon; a failed send leaves the server its fallback read
        Task { _ = try? await connection?.request(AppsTeamEventRequest(event: "cloud.machine.state", data: value)) }
        switch value["t"]?.stringValue {
        case "state":
            guard let record = value["state"]?["record"], let shown = CloudMachine(next: record) else { return }
            last[machine] = shown
            onRecord(shown)
        case "removed":
            guard var gone = last.removeValue(forKey: machine) else { return }
            gone.status = .destroyed
            onRecord(gone)
        default:
            return
        }
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
