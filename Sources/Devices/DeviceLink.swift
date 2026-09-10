import CMUXMobileCore
import CmuxMobileRPC
import Foundation
import OSLog

private let deviceLinkLog = Logger(subsystem: "dev.cmux", category: "device-link")

/// Errors a device link raises to its provider and mirror sessions.
enum DeviceLinkError: Error, LocalizedError, Equatable {
    case notConnected
    case blocked(String)
    case hostRejected(code: String?, message: String)
    case malformedResponse(String)
    /// The host's status carried no identity: it did not accept this account.
    case identityUnproven
    /// The host answered as a different Mac (or app instance) than the one dialed.
    case identityMismatch

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return String(localized: "devices.link.error.notConnected", defaultValue: "This Mac is not connected right now.")
        case .blocked(let reason):
            return reason
        case .hostRejected(_, let message):
            return message
        case .malformedResponse(let what):
            return String(format: String(localized: "devices.link.error.malformed", defaultValue: "The Mac sent an unexpected reply for %@."), what)
        case .identityUnproven:
            return String(localized: "devices.link.error.identityUnproven", defaultValue: "This Mac did not confirm it is signed into your account.")
        case .identityMismatch:
            return String(localized: "devices.link.error.identityMismatch", defaultValue: "A different Mac answered at this address. Pair it again from Settings \u{203A} Computers.")
        }
    }
}

/// One live connection from this Mac to another Mac's cmux app: the shared
/// mobile RPC client over the route ``DeviceRouteSelector`` picked with the
/// pairing store's grant, the synced workspace mirror (`mobile.sync.fetch` +
/// `mobile.sync.delta`), the terminal event fan-out, and the reconnect state
/// machine that keeps all of it alive across network blips, remote app
/// restarts, presence flips, and pairing changes.
///
/// Every (re)connect proves the host's identity before it subscribes: the
/// first request is the authenticated pair (a read-only probe plus the host's
/// identity-bearing status), checked against the exact device and app
/// instance this row names. Liveness is push: the RPC session finishes the
/// event stream when its transport tears down, and that ending is what
/// reconnects the link; nothing here polls.
@MainActor
final class DeviceLink {
    typealias Phase = DeviceLinkReconnectPolicy.Phase

    static let eventTopics: Set<String> = ["mobile.sync.delta", "workspace.updated", "terminal.bytes", "terminal.updated"]

    let instance: SurfaceDeviceInstanceID
    private(set) var record: DeviceDirectoryRecord
    private(set) var phase: Phase = .idle
    private(set) var lastFailure: String?
    /// The device is online and this account's, but the pairing store holds no
    /// grant for any of its routes; the row says so instead of dialing.
    private(set) var needsAuthorization = false
    let mirror = MobileStateSyncMirror()
    let terminalEvents = DeviceLinkTerminalEvents()
    /// A stable per-link client id: the host keys viewport reports and
    /// subscriptions by it, so a reconnect replaces rather than duplicates them.
    let clientID = "mac-" + UUID().uuidString.lowercased()
    /// Fires after any change a provider should publish (phase, mirror, record).
    var onChange: (@MainActor () -> Void)?

    private let runtime: DeviceLinkRuntime
    private let authorization: any DeviceLinkAuthorizationSource
    private let routeSelector: DeviceRouteSelector
    private let clock: any Clock<Duration>
    private var policy = DeviceLinkReconnectPolicy()
    private var client: MobileCoreRPCClient?
    private var connectTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var waitTask: Task<Void, Never>?
    private var fetchTask: Task<Void, Never>?
    private var streamID = UUID().uuidString.lowercased()
    private var generation: UInt64 = 0

    init(
        record: DeviceDirectoryRecord,
        runtime: DeviceLinkRuntime,
        authorization: any DeviceLinkAuthorizationSource,
        routeSelector: DeviceRouteSelector = DeviceRouteSelector(),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        instance = record.instance
        self.record = record
        self.runtime = runtime
        self.authorization = authorization
        self.routeSelector = routeSelector
        self.clock = clock
    }

    var isConnected: Bool { phase == .connected }

    // MARK: - Inputs

    func update(record: DeviceDirectoryRecord) {
        let routesChanged = record.routes != self.record.routes
        self.record = record
        reevaluate(unblock: routesChanged)
    }

    /// The pairing store changed: a new grant makes this device dialable at
    /// once; a removed one drops the live link.
    func authorizationDidChange() {
        reevaluate(unblock: true)
    }

    func refresh() {
        transition(applyPolicy(.refreshRequested))
        if phase == .connected { scheduleFetch() }
    }

    func stop() {
        transition(applyPolicy(.stopped))
        mirror.reset()
        onChange?()
    }

    /// A session or mutation saw the transport fail; reconnect from a fresh dial.
    func reportTransportLost(_ error: any Error) {
        deviceLinkLog.error("device link lost \(self.instance.wireValue, privacy: .public): \(String(describing: error), privacy: .public)")
        lastFailure = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        transition(applyPolicy(.transportLost))
        onChange?()
    }

    private func applyPolicy(_ event: DeviceLinkReconnectPolicy.Event) -> Phase {
        policy.apply(event, now: runtime.now())
    }

    private func reevaluate(unblock: Bool) {
        var granted = false
        var needsAuthorization = false
        do {
            _ = try selectRoute()
            granted = true
        } catch DeviceRouteSelector.SelectionError.needsAuthorization {
            needsAuthorization = true
        } catch {
            granted = false
        }
        self.needsAuthorization = record.isDialable && needsAuthorization
        if unblock, case .blocked = phase {
            policy = DeviceLinkReconnectPolicy()
        }
        transition(applyPolicy(.directory(dialable: record.isDialable && granted)))
        onChange?()
    }

    private func selectRoute() throws -> DeviceRouteSelector.Selection {
        try routeSelector.select(from: record.routes, instance: instance) { [authorization, instance] route in
            authorization.authorization(for: instance, route: route)
        }
    }

    // MARK: - RPC

    /// One request on the live link. Host-reported failures come back as
    /// ``DeviceLinkError/hostRejected``; a closed transport reconnects the link.
    func request(_ method: String, params: [String: Any] = [:], timeoutNanoseconds: UInt64? = nil) async throws -> [String: Any] {
        guard let client, phase == .connected else { throw DeviceLinkError.notConnected }
        let requestData = try MobileCoreRPCClient.requestData(method: method, params: params)
        do {
            let data = try await client.sendRequest(requestData, timeoutNanoseconds: timeoutNanoseconds)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw DeviceLinkError.malformedResponse(method)
            }
            return object
        } catch let error as MobileShellConnectionError {
            switch error {
            case .rpcError(let code, let message):
                throw DeviceLinkError.hostRejected(code: code, message: message)
            case .connectionClosed, .requestTimedOut, .transportWriteTimedOut:
                reportTransportLost(error)
                throw DeviceLinkError.notConnected
            default:
                throw DeviceLinkError.hostRejected(code: nil, message: error.localizedDescription)
            }
        }
    }

    // MARK: - State machine

    private func transition(_ next: Phase) {
        guard next != phase else { return }
        let previous = phase
        phase = next
        deviceLinkLog.info("device link \(self.instance.wireValue, privacy: .public): \(String(describing: previous), privacy: .public) -> \(String(describing: next), privacy: .public)")
        switch next {
        case .connecting(let attempt):
            tearDownClient(notify: previous == .connected)
            startConnect(attempt: attempt)
        case .waiting(_, let delay):
            tearDownClient(notify: previous == .connected)
            // Bounded, cancellable backoff on the injected clock, the same
            // shape `CloudMachineLink` and the presence heartbeat use.
            waitTask = Task { [weak self] in
                guard let self else { return }
                guard (try? await self.clock.sleep(for: delay)) != nil else { return }
                self.transition(self.applyPolicy(.waitElapsed))
                self.onChange?()
            }
        case .idle, .blocked:
            tearDownClient(notify: previous == .connected)
        case .connected:
            break
        }
    }

    private func tearDownClient(notify: Bool) {
        generation &+= 1
        connectTask?.cancel()
        connectTask = nil
        waitTask?.cancel()
        waitTask = nil
        eventTask?.cancel()
        eventTask = nil
        fetchTask?.cancel()
        fetchTask = nil
        if notify { terminalEvents.broadcast(.linkLost) }
        if let client {
            self.client = nil
            Task { await client.disconnect() }
        }
    }

    private func startConnect(attempt: Int) {
        let generation = self.generation
        let record = self.record
        connectTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (client, events) = try await self.makeConnectedClient(record: record)
                guard !Task.isCancelled, generation == self.generation else {
                    await client.disconnect()
                    return
                }
                self.client = client
                self.lastFailure = nil
                self.transition(self.applyPolicy(.connectSucceeded))
                self.startEventConsumer(events, generation: generation)
                await self.performFetch(generation: generation)
                self.terminalEvents.broadcast(.linkReconnected)
                self.onChange?()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, generation == self.generation else { return }
                let classified = Self.classify(error)
                self.lastFailure = classified.reason
                deviceLinkLog.error("device link connect failed \(self.instance.wireValue, privacy: .public) attempt=\(attempt): \(classified.reason, privacy: .public)")
                self.transition(self.applyPolicy(.connectFailed(retryable: classified.retryable, reason: classified.reason)))
                self.onChange?()
            }
        }
    }

    /// The dial: route and grant, identity proof, then the subscription. The
    /// event listener attaches before the host subscribes so no event between
    /// the two is lost.
    private func makeConnectedClient(
        record: DeviceDirectoryRecord
    ) async throws -> (client: MobileCoreRPCClient, events: AsyncStream<MobileEventEnvelope>) {
        let selection = try selectRoute()
        let ticket = try CmxAttachTicket(
            workspaceID: "workspace-main",
            terminalID: nil,
            macDeviceID: record.instance.deviceID,
            macDisplayName: record.deviceName,
            routes: [selection.route]
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: selection.route,
            ticket: ticket,
            // The account's Stack bearer authenticates the RPC; the pairing
            // grant is what lets it travel over this Tailscale peer at all.
            allowsStackAuthFallback: true,
            legacyTailscaleAuthorizationEvidence: selection.evidence,
            sessionPurpose: .backgroundControl
        )
        do {
            streamID = UUID().uuidString.lowercased()
            let timeout = runtime.pairingRequestTimeoutNanoseconds
            // Identity first. The probe is read-only and authenticated, and the
            // paired status reply names the Mac that answered; nothing is
            // subscribed or exposed until that matches this row exactly.
            let probe = try MobileCoreRPCClient.requestData(method: "mobile.events.probe", params: [
                "client_id": clientID,
                "stream_id": streamID,
            ])
            let (_, status) = try await client.sendRequestAndAuthenticatedHostStatus(
                probe,
                timeoutNanoseconds: timeout,
                hostStatusTimeoutNanoseconds: { timeout }
            )
            try DeviceLinkHostIdentity.verify(statusResponse: status, expected: instance)
            let events = await client.subscribe(to: Self.eventTopics)
            let subscribe = try await client.sendRequest(
                MobileCoreRPCClient.requestData(method: "mobile.events.subscribe", params: [
                    "client_id": clientID,
                    "stream_id": streamID,
                    "topics": Array(Self.eventTopics).sorted(),
                ]),
                timeoutNanoseconds: timeout
            )
            guard let object = try JSONSerialization.jsonObject(with: subscribe) as? [String: Any],
                  object["stream_id"] as? String == streamID else {
                throw DeviceLinkError.malformedResponse("mobile.events.subscribe")
            }
            return (client, events)
        } catch {
            await client.disconnect()
            throw error
        }
    }

    private static func classify(_ error: any Error) -> (retryable: Bool, reason: String) {
        if let error = error as? DeviceRouteSelector.SelectionError {
            switch error {
            case .noRoutes:
                return (false, String(localized: "devices.link.error.noRoutes", defaultValue: "This Mac has not published a route yet."))
            case .needsAuthorization:
                return (false, String(localized: "devices.link.error.needsAuthorization", defaultValue: "Pair this Mac in Settings \u{203A} Computers to connect."))
            case .noDialableRoute:
                return (false, String(localized: "devices.link.error.noDialableRoute", defaultValue: "This Mac is only reachable over a transport this build cannot dial (Tailscale is required)."))
            }
        }
        if let error = error as? DeviceLinkError {
            switch error {
            case .identityUnproven, .identityMismatch:
                return (false, error.errorDescription ?? String(describing: error))
            case .blocked(let reason):
                return (false, reason)
            case .notConnected, .hostRejected, .malformedResponse:
                return (true, error.errorDescription ?? String(describing: error))
            }
        }
        if let error = error as? MobileShellConnectionError {
            switch error {
            case .accountMismatch(let message), .authorizationFailed(let message):
                return (false, message)
            case .insecureManualRoute:
                return (false, error.localizedDescription)
            default:
                return (true, error.localizedDescription)
            }
        }
        return (true, (error as? LocalizedError)?.errorDescription ?? String(describing: error))
    }

    // MARK: - Sync and events

    /// The explicit Refresh verb's awaitable half: re-fetch the synced tree now
    /// on a live link (a reconnect fetches on its own).
    func fetchNow() async {
        guard phase == .connected else { return }
        await performFetch(generation: generation)
    }

    private func scheduleFetch() {
        guard fetchTask == nil else { return }
        let generation = self.generation
        fetchTask = Task { [weak self] in
            await self?.performFetch(generation: generation)
            self?.fetchTask = nil
        }
    }

    private func performFetch(generation: UInt64) async {
        guard generation == self.generation else { return }
        let coder = MobileSyncFrameCoder()
        do {
            let params = try coder.jsonObject(from: mirror.fetchRequest)
            let object = try await request("mobile.sync.fetch", params: params)
            guard generation == self.generation else { return }
            let response = try coder.decode(MobileSyncFetchResponse.self, fromJSONObject: object)
            if mirror.apply(response: response) == .gap {
                // The cursor fell behind the host's tombstone ring: cold start.
                mirror.reset()
                let cold = try coder.jsonObject(from: mirror.fetchRequest)
                let retry = try await request("mobile.sync.fetch", params: cold)
                guard generation == self.generation else { return }
                _ = mirror.apply(response: try coder.decode(MobileSyncFetchResponse.self, fromJSONObject: retry))
            }
            onChange?()
        } catch {
            guard generation == self.generation else { return }
            deviceLinkLog.error("device sync fetch failed \(self.instance.wireValue, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// Consume host events until the session ends the stream. The RPC session
    /// finishes every listener when its transport tears down, so the stream
    /// ending while this generation is current is the push signal that the
    /// link is gone; the reconnect dial follows at once.
    private func startEventConsumer(_ events: AsyncStream<MobileEventEnvelope>, generation: UInt64) {
        eventTask = Task { [weak self] in
            for await envelope in events {
                guard let self, !Task.isCancelled, generation == self.generation else { return }
                self.handle(envelope)
            }
            guard let self, !Task.isCancelled, generation == self.generation else { return }
            self.reportTransportLost(MobileShellConnectionError.connectionClosed)
        }
    }

    private func handle(_ envelope: MobileEventEnvelope) {
        switch envelope.topic {
        case "mobile.sync.delta":
            applyDelta(envelope.payloadJSON)
        case "terminal.bytes", "terminal.updated":
            if let decoded = DeviceTerminalEvent.decode(envelope) {
                terminalEvents.send(decoded.event, surfaceID: decoded.surfaceID)
            }
        default:
            break
        }
    }

    private func applyDelta(_ payload: Data?) {
        guard let payload,
              let header = try? JSONDecoder().decode(MobileSyncDeltaEventHeader.self, from: payload) else {
            scheduleFetch()
            return
        }
        let result: MobileSyncApplyResult
        switch header.collection {
        case .workspaces:
            guard let delta = try? JSONDecoder().decode(MobileSyncDeltaEvent<WorkspaceSyncRecord>.self, from: payload) else {
                scheduleFetch()
                return
            }
            result = mirror.workspaces.apply(delta: delta)
        case .groups:
            guard let delta = try? JSONDecoder().decode(MobileSyncDeltaEvent<GroupSyncRecord>.self, from: payload) else {
                scheduleFetch()
                return
            }
            result = mirror.groups.apply(delta: delta)
        default:
            return
        }
        switch result {
        case .applied: onChange?()
        case .gap: scheduleFetch()
        case .staleIgnored: break
        }
    }
}
