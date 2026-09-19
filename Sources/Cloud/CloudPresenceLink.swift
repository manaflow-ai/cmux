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

    /// A burst sends its first update immediately and its newest pending
    /// update at the next interval, including when the mouse then stops.
    static let minimumPublishInterval: TimeInterval = 1.0 / 30.0

    let machineID: String
    private(set) var socketPath: String
    private(set) var phase: Phase = .connecting
    private(set) var serverSupportsPresence = false

    private let commandBuilder = CloudTuiManualIOCommand()
    private let clientName: String
    private var connection: CloudTuiManualIOConnection?
    private var connectTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var pendingPublishTask: Task<Void, Never>?
    private var nextRequestID: UInt64 = 1
    private var identifyRequestID: UInt64 = 0
    private var listClientsRequestID: UInt64 = 0
    private var subscribeRequestID: UInt64 = 0
    private var selfClientID: UInt64?
    private var reconnectAttempt = 0
    private var stopping = false
    private var lastPublish: TimeInterval = 0
    /// The local UI's desired state survives a transport reconnect.
    private var desiredPresence: (surface: UInt64, pointer: CloudPresenceAnchor?, highlight: CloudPresenceHighlight?)?
    /// State most recently sent on the current connection.
    private var lastSentPresence: (surface: UInt64, pointer: CloudPresenceAnchor?, highlight: CloudPresenceHighlight?)?
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
        self.clientName = clientName
        self.onEntry = onEntry
        self.onPhaseChange = onPhaseChange
        startConnection()
    }

    private func startConnection() {
        guard !stopping else { return }
        phase = .connecting
        selfClientID = nil
        subscribeRequestID = 0
        lastSentPresence = nil
        lastPublish = 0
        connectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let connection = CloudTuiManualIOConnection(
                socketPath: socketPath,
                queue: DispatchQueue(label: "com.cmux.cloud-presence", qos: .userInitiated)
            )
            do {
                try await connection.start()
            } catch {
                connection.close()
                guard !Task.isCancelled else { return }
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
            connection.send(.identify(id: identify, request: .init()))
            let clientInfoID = self.takeRequestID()
            connection.send(.setClientInfo(
                id: clientInfoID,
                request: .init(
                    capabilities: .value([self.commandBuilder.presenceCapability]),
                    kind: .value("mac"),
                    name: .value(self.clientName)
                )
            ))
        }
    }

    func stop() {
        stopping = true
        connectTask?.cancel()
        eventTask?.cancel()
        reconnectTask?.cancel()
        reconnectTask = nil
        pendingPublishTask?.cancel()
        pendingPublishTask = nil
        desiredPresence = nil
        if phase == .ready, let connection, lastSentPresence != nil {
            connection.send(.presenceClear(id: takeRequestID(), request: .init()))
        }
        lastSentPresence = nil
        connection?.close()
        connection = nil
        transition(to: .disconnected)
    }

    /// Publishes a pointer and highlight, or a pointer-less state when the
    /// mouse left the pane. Identical repeats are dropped.
    func publish(surfaceID: UInt64, pointer: CloudPresenceAnchor?, highlight: CloudPresenceHighlight?) {
        guard surfaceID > 0 else { return }
        desiredPresence = (surfaceID, pointer, highlight)
        guard phase == .ready, serverSupportsPresence, let connection else { return }
        let now = Date().timeIntervalSinceReferenceDate
        // Pointer moves are throttled; a highlight edge or a pointer clear is
        // always sent so the last state on the wire is the settled one.
        let settled = pointer == nil || highlight != lastSentPresence?.highlight || surfaceID != lastSentPresence?.surface
        if let last = lastSentPresence,
           last.surface == surfaceID, last.pointer == pointer, last.highlight == highlight,
           !settled {
            return
        }
        if !settled, now - lastPublish < Self.minimumPublishInterval {
            schedulePendingPublish(now: now)
            return
        }
        pendingPublishTask?.cancel()
        pendingPublishTask = nil
        sendPresence(
            surfaceID: surfaceID,
            pointer: pointer,
            highlight: highlight,
            on: connection,
            force: settled,
            now: now
        )
    }

    func clear() {
        desiredPresence = nil
        pendingPublishTask?.cancel()
        pendingPublishTask = nil
        guard phase == .ready, serverSupportsPresence, let connection else { return }
        guard lastSentPresence != nil else { return }
        lastSentPresence = nil
        connection.send(.presenceClear(id: takeRequestID(), request: .init()))
    }

    /// Carrier replacement keeps the desired presence while retiring the
    /// old stream. The subscription acknowledgement publishes it again.
    func reconnect(socketPath: String) {
        guard self.socketPath != socketPath, !stopping else { return }
        self.socketPath = socketPath
        transition(to: .disconnected)
        reconnectTask?.cancel()
        reconnectTask = nil
        startConnection()
    }

    private func schedulePendingPublish(now: TimeInterval) {
        guard pendingPublishTask == nil else { return }
        let delay = max(0, Self.minimumPublishInterval - (now - lastPublish))
        pendingPublishTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.pendingPublishTask = nil
            guard let desired = self.desiredPresence else { return }
            self.publish(surfaceID: desired.surface, pointer: desired.pointer, highlight: desired.highlight)
        }
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
            if requestID == subscribeRequestID, subscribeRequestID != 0 {
                subscribeRequestID = 0
                guard ok else {
                    transition(to: .disconnected)
                    return
                }
                transition(to: .ready)
                if let desired = desiredPresence {
                    sendPresence(surfaceID: desired.surface, pointer: desired.pointer,
                                 highlight: desired.highlight, on: connection, force: true,
                                 now: Date().timeIntervalSinceReferenceDate)
                }
                return
            }
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
                connection.send(.listClients(id: listRequestID, request: .init()))
                return
            }
            guard requestID == listClientsRequestID else { return }
            listClientsRequestID = 0
            guard ok, let clientID else {
                transition(to: .disconnected)
                return
            }
            selfClientID = clientID
            subscribeRequestID = takeRequestID()
            connection.send(.subscribe(id: subscribeRequestID, request: .init(presenceOnly: .value(true))))
        case .snapshot, .output, .resized, .colorsChanged, .detached:
            return
        case .message:
            // Resource-multiplexer envelopes are unrelated to this legacy
            // presence-only connection. Keep the stream isolated from them.
            return
        case .overflow:
            transition(to: .disconnected)
        }
    }

    private func takeRequestID() -> UInt64 {
        defer { nextRequestID &+= 1 }
        return nextRequestID
    }

    private func sendPresence(
        surfaceID: UInt64,
        pointer: CloudPresenceAnchor?,
        highlight: CloudPresenceHighlight?,
        on connection: CloudTuiManualIOConnection,
        force: Bool,
        now: TimeInterval
    ) {
        if !force, now - lastPublish < Self.minimumPublishInterval {
            return
        }
        lastPublish = now
        lastSentPresence = (surfaceID, pointer, highlight)
        let request = CloudTuiGenerated.PresenceUpdateRequest(
            highlight: highlight.map(CloudTuiGenerated.OptionalField.value) ?? .missing,
            pointer: pointer.map(CloudTuiGenerated.OptionalField.value) ?? .missing,
            surface: surfaceID
        )
        connection.send(.presenceUpdate(id: takeRequestID(), request: request))
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
            tearDownConnection()
            scheduleReconnect()
        }
        onPhaseChange(self)
    }

    private func tearDownConnection() {
        connectTask?.cancel()
        connectTask = nil
        eventTask?.cancel()
        eventTask = nil
        pendingPublishTask?.cancel()
        pendingPublishTask = nil
        connection?.close()
        connection = nil
        lastSentPresence = nil
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
