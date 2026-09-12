import Foundation

/// One presence-only control connection per cloud machine.
///
/// The link never attaches a surface. It identifies, names itself, subscribes
/// with `presence_only`, and then forwards every `presence-changed` frame to
/// its owner while publishing this Mac's own pointer at a bounded rate.
/// When the socket closes the link reports `.disconnected` and retries with a
/// bounded backoff while its pane registration remains alive.
@MainActor
final class CloudPresenceLink {
    enum Phase: Equatable {
        case connecting
        case ready
        case disconnected
    }

    /// Updates faster than this are dropped on the sender; the daemon also
    /// caps at 240/s and the event bus coalesces per client, so a dropped
    /// move is replaced by the next one within a frame.
    static let minimumPublishInterval: TimeInterval = 1.0 / 30.0

    let machineID: String
    let socketPath: String
    private(set) var phase: Phase = .connecting
    private(set) var serverSupportsPresence = false

    private let commandBuilder = CloudTuiManualIOCommand()
    private var connection: CloudTuiManualIOConnection?
    private var connectTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var nextRequestID: UInt64 = 1
    private var identifyRequestID: UInt64 = 0
    private var listClientsRequestID: UInt64 = 0
    private var selfClientID: UInt64?
    private var reconnectAttempt = 0
    private var stopping = false
    private var lastPublish: TimeInterval = 0
    private var lastPublished: (surface: UInt64, pointer: CloudPresenceAnchor?, highlight: CloudPresenceHighlight?)?
    private let onEntry: @MainActor (CloudPresenceEntry) -> Void
    private let onPhaseChange: @MainActor (CloudPresenceLink) -> Void

    init(
        machineID: String,
        socketPath: String,
        clientName: String,
        onEntry: @escaping @MainActor (CloudPresenceEntry) -> Void,
        onPhaseChange: @escaping @MainActor (CloudPresenceLink) -> Void
    ) {
        self.machineID = machineID
        self.socketPath = socketPath
        self.onEntry = onEntry
        self.onPhaseChange = onPhaseChange
        startConnection()
    }

    private func startConnection() {
        guard !stopping else { return }
        phase = .connecting
        selfClientID = nil
        connectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let connection = CloudTuiManualIOConnection(
                socketPath: socketPath,
                queue: DispatchQueue(label: "com.cmux.cloud-presence", qos: .userInitiated)
            )
            do {
                try await connection.start()
            } catch {
                guard !Task.isCancelled else { return }
                connection.close()
                self.transition(to: .disconnected)
                return
            }
            guard !Task.isCancelled, !self.stopping, self.phase == .connecting else {
                connection.close()
                return
            }
            self.connection = connection
            self.startEventTask(connection)
            let identify = self.takeRequestID()
            self.identifyRequestID = identify
            connection.send(self.commandBuilder.identify(requestID: identify))
            connection.send(
                self.commandBuilder.setPresenceClientInfo(
                    name: clientName,
                    kind: "mac",
                    requestID: self.takeRequestID()
                )
            )
        }
    }

    func stop() {
        stopping = true
        connectTask?.cancel()
        eventTask?.cancel()
        reconnectTask?.cancel()
        reconnectTask = nil
        if phase == .ready, let connection {
            connection.send(commandBuilder.presenceClear(requestID: takeRequestID()))
        }
        connection?.close()
        connection = nil
        transition(to: .disconnected)
    }

    /// Publishes a pointer and highlight, or a pointer-less state when the
    /// mouse left the pane. Identical repeats are dropped.
    func publish(surfaceID: UInt64, pointer: CloudPresenceAnchor?, highlight: CloudPresenceHighlight?) {
        guard phase == .ready, serverSupportsPresence, let connection else { return }
        if let last = lastPublished,
           last.surface == surfaceID, last.pointer == pointer, last.highlight == highlight {
            return
        }
        let now = Date().timeIntervalSinceReferenceDate
        // Pointer moves are throttled; a highlight edge or a pointer clear is
        // always sent so the last state on the wire is the settled one.
        let settled = pointer == nil || highlight != lastPublished?.highlight || surfaceID != lastPublished?.surface
        if !settled, now - lastPublish < Self.minimumPublishInterval { return }
        lastPublish = now
        lastPublished = (surfaceID, pointer, highlight)
        connection.send(
            commandBuilder.presenceUpdate(
                surfaceID: surfaceID,
                pointer: pointer,
                highlight: highlight,
                requestID: takeRequestID()
            )
        )
    }

    func clear() {
        guard phase == .ready, serverSupportsPresence, let connection else { return }
        guard lastPublished != nil else { return }
        lastPublished = nil
        connection.send(commandBuilder.presenceClear(requestID: takeRequestID()))
    }

    private func startEventTask(_ connection: CloudTuiManualIOConnection) {
        eventTask?.cancel()
        eventTask = Task { @MainActor [weak self, connection] in
            for await frame in connection.events {
                guard let self, !Task.isCancelled else { return }
                self.handle(frame: frame, on: connection)
            }
            guard let self, self.connection === connection else { return }
            self.transition(to: .disconnected)
        }
    }

    private func handle(frame: CloudTuiManualIOFrame, on connection: CloudTuiManualIOConnection) {
        switch frame {
        case let .presence(entry):
            guard entry.client != selfClientID else { return }
            onEntry(entry)
        case let .response(requestID, ok, _, capabilities, _, _, _, clientID):
            if requestID == identifyRequestID {
                identifyRequestID = 0
                guard ok else {
                    transition(to: .disconnected)
                    return
                }
                serverSupportsPresence = capabilities.contains(commandBuilder.presenceCapability)
                guard serverSupportsPresence else {
                    transition(to: .ready)
                    return
                }
                let listRequestID = takeRequestID()
                listClientsRequestID = listRequestID
                connection.send(commandBuilder.listClients(requestID: listRequestID))
                return
            }
            guard requestID == listClientsRequestID else { return }
            listClientsRequestID = 0
            guard ok, let clientID else {
                transition(to: .disconnected)
                return
            }
            selfClientID = clientID
            connection.send(commandBuilder.subscribePresence(requestID: takeRequestID()))
            transition(to: .ready)
        case .snapshot, .output, .resized, .detached:
            return
        case .overflow:
            transition(to: .disconnected)
        }
    }

    private func takeRequestID() -> UInt64 {
        defer { nextRequestID &+= 1 }
        return nextRequestID
    }

    private func transition(to phase: Phase) {
        guard self.phase != phase else {
            if phase == .disconnected { scheduleReconnect() }
            return
        }
        self.phase = phase
        if phase == .ready {
            reconnectAttempt = 0
        } else if phase == .disconnected {
            scheduleReconnect()
        }
        onPhaseChange(self)
    }

    private func scheduleReconnect() {
        guard !stopping, reconnectTask == nil else { return }
        let delay = min(30, 1 << min(reconnectAttempt, 5))
        reconnectAttempt = min(reconnectAttempt + 1, 5)
        reconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled, !self.stopping else { return }
            self.reconnectTask = nil
            self.transition(to: .connecting)
            self.startConnection()
        }
    }
}
