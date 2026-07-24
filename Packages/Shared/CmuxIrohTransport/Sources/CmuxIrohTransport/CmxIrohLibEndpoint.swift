import CMUXMobileCore
import Foundation
import IrohLib

actor CmxIrohLibEndpoint: CmxIrohEndpoint {
    private let driver: Endpoint
    private let peerIdentity: CmxIrohPeerIdentity
    private let alpns: Set<Data>
    private let transportVerificationMode: CmxIrohTransportVerificationMode
    private var relayProfile: CmxIrohEndpointRelayProfile
    private var relayConfigurations: [String: CmxIrohEndpointRelayProfile.Relay]
    private var addressWatch: WatchHandle?
    private var onlineTask: Task<Void, Never>?
    private var closureTask: Task<Void, Never>?
    private var closing = false
    private var closed = false
    private var reachedOnline = false
    private var observedAddressSnapshot: EndpointAddr?
    private var terminalHealthEvent: CmxIrohEndpointHealthEvent?
    private var observers: [
        UUID: AsyncStream<CmxIrohEndpointHealthEvent>.Continuation
    ] = [:]

    init(
        driver: Endpoint,
        identity: CmxIrohPeerIdentity,
        configuration: CmxIrohEndpointConfiguration,
        transportVerificationMode: CmxIrohTransportVerificationMode = .automatic
    ) {
        self.driver = driver
        peerIdentity = identity
        alpns = Set(configuration.alpns)
        self.transportVerificationMode = transportVerificationMode
        relayProfile = configuration.relayProfile
        relayConfigurations = Dictionary(
            uniqueKeysWithValues: configuration.relayProfile.activeRelays.map { ($0.url, $0) }
        )
    }

    func startMonitoring() {
        guard addressWatch == nil, closureTask == nil else { return }
        // Iroh's `network_change()` is an input that tells the endpoint to
        // rescan, not an observable event. `watchAddr` is the authoritative
        // output for route changes after Iroh's native network monitor runs.
        addressWatch = driver.watchAddr(
            callback: CmxIrohLibAddressChangeCallback { [weak self] address in
                await self?.recordAddressSnapshot(address)
            }
        )
        let driver = driver
        onlineTask = Task { [weak self] in
            await driver.online()
            guard !Task.isCancelled else { return }
            await self?.recordHealthEvent(.online)
        }
        closureTask = Task { [weak self] in
            await driver.closed()
            guard !Task.isCancelled else { return }
            await self?.driverDidClose()
        }
    }

    func identity() -> CmxIrohPeerIdentity {
        peerIdentity
    }

    func address() -> CmxIrohEndpointAddress {
        let address = observedAddressSnapshot ?? driver.addr()
        let now = Date()
        let expiresAt = now.addingTimeInterval(CmxIrohPathHint.maximumPrivateHintTTL)
        var hints: [CmxIrohPathHint] = []
        if transportVerificationMode != .directOnly,
           let relayURL = address.relayUrl(),
           relayProfile.allowedRelayURLs.contains(relayURL),
           let hint = try? CmxIrohPathHint(
               kind: .relayURL,
               value: relayURL,
               source: .native,
               privacyScope: .publicInternet,
               observedAt: now,
               expiresAt: expiresAt
           ) {
            hints.append(hint)
        }
        if transportVerificationMode != .relayOnly {
            hints.append(contentsOf: address.directAddresses().compactMap { value in
                try? CmxIrohPathHint(
                    kind: .directAddress,
                    value: value,
                    source: .native,
                    privacyScope: .publicInternet,
                    observedAt: now,
                    expiresAt: expiresAt
                )
            })
        }
        return CmxIrohEndpointAddress(identity: peerIdentity, pathHints: hints)
    }

    func localDirectAddresses() -> [String] {
        transportVerificationMode == .relayOnly
            ? []
            : (observedAddressSnapshot ?? driver.addr()).directAddresses()
    }

    func connect(
        to address: CmxIrohEndpointAddress,
        alpn: Data
    ) async throws -> any CmxIrohConnection {
        guard alpns.contains(alpn) else { throw CmxIrohLibError.unexpectedALPN }
        var lastError: (any Error)?
        for endpointAddress in try endpointAddresses(address) {
            do {
                try Task.checkCancellation()
                let connection = try await driver.connect(addr: endpointAddress, alpn: alpn)
                let wrapped = try CmxIrohLibConnection(driver: connection)
                guard await wrapped.remoteIdentity() == address.identity else {
                    await wrapped.close(errorCode: 1, reason: "identity_mismatch")
                    throw CmxIrohLibError.remoteIdentityMismatch
                }
                return wrapped
            } catch CmxIrohLibError.remoteIdentityMismatch {
                throw CmxIrohLibError.remoteIdentityMismatch
            } catch {
                try Task.checkCancellation()
                lastError = error
            }
        }
        throw lastError ?? CmxIrohLibError.invalidEndpointIdentity
    }

    func accept() async throws -> (any CmxIrohConnection)? {
        guard let incoming = await driver.acceptNext() else { return nil }
        let accepting = try await incoming.accept()
        guard alpns.contains(try await accepting.alpn()) else {
            throw CmxIrohLibError.unexpectedALPN
        }
        return try CmxIrohLibConnection(driver: await accepting.connect())
    }

    func replaceRelays(_ relays: [CmxIrohRelayConfiguration]) async throws {
        let profile = try relayProfile.replacingManagedRelays(relays)
        try await replaceRelayProfile(profile)
    }

    func replaceRelayProfile(_ profile: CmxIrohEndpointRelayProfile) async throws {
        if transportVerificationMode == .directOnly {
            relayProfile = profile
            relayConfigurations = [:]
            return
        }
        let next = Dictionary(
            uniqueKeysWithValues: profile.activeRelays.map { ($0.url, $0) }
        )
        let now = Date()
        for relay in profile.activeRelays {
            guard profile.allowedRelayURLs.contains(relay.url) else {
                throw CmxIrohLibError.unmanagedRelayURL(relay.url)
            }
            guard relay.isUsable(at: now) else {
                throw CmxIrohLibError.expiredRelayCredential(relay.url)
            }
        }

        let previous = relayConfigurations
        do {
            for relay in profile.activeRelays {
                try await driver.insertRelay(config: Self.relayConfig(relay))
            }
            for staleURL in previous.keys where next[staleURL] == nil {
                _ = try await driver.removeRelay(url: staleURL)
            }
        } catch {
            let restored = await restoreRelayConfigurations(
                previous: previous,
                attempted: next
            )
            if !restored {
                // A partially mutated driver is no longer safe to publish. Its
                // health observer will recreate the same EndpointID from the
                // supervisor's unchanged last-known-good configuration.
                try? await driver.close()
            }
            throw error
        }
        relayProfile = profile
        relayConfigurations = next
    }

    func healthEvents() -> AsyncStream<CmxIrohEndpointHealthEvent> {
        let observerID = UUID()
        return AsyncStream { continuation in
            if let terminalHealthEvent {
                continuation.yield(terminalHealthEvent)
                continuation.finish()
                return
            }
            guard !closed else {
                continuation.finish()
                return
            }
            observers[observerID] = continuation
            if reachedOnline {
                continuation.yield(.online)
            }
            if observedAddressSnapshot != nil {
                continuation.yield(.networkChanged)
            }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(observerID) }
            }
        }
    }

    func isHealthy() -> Bool {
        !closing && !closed
    }

    func close() async {
        guard !closing, !closed else { return }
        closing = true
        onlineTask?.cancel()
        closureTask?.cancel()
        onlineTask = nil
        closureTask = nil
        await addressWatch?.stop()
        addressWatch = nil
        try? await driver.close()
        closed = true
        finishObservers()
    }

    func endpointAddresses(
        _ value: CmxIrohEndpointAddress
    ) throws -> [EndpointAddr] {
        let now = Date()
        let usable = value.pathHints.filter { $0.isUsable(at: now) }
        if usable.contains(where: { $0.kind == .relayIdentifier }) {
            throw CmxIrohLibError.unsupportedRelayIdentifier
        }
        var relayURLs: [String] = []
        var observedRelayURLs = Set<String>()
        var directAddresses: [String] = []
        var observedDirectAddresses = Set<String>()
        for hint in usable {
            switch hint.kind {
            case .relayURL:
                guard transportVerificationMode != .directOnly else { continue }
                guard relayProfile.allowedRelayURLs.contains(hint.value) else {
                    throw CmxIrohLibError.unmanagedRelayURL(hint.value)
                }
                if observedRelayURLs.insert(hint.value).inserted {
                    relayURLs.append(hint.value)
                }
            case .directAddress:
                guard transportVerificationMode != .relayOnly else { continue }
                if observedDirectAddresses.insert(hint.value).inserted {
                    directAddresses.append(hint.value)
                }
            case .relayIdentifier:
                break
            }
        }
        let endpointID = try CmxIrohLibIdentity.endpointID(value.identity)
        if relayURLs.isEmpty {
            return [EndpointAddr(id: endpointID, relayUrl: nil, addresses: directAddresses)]
        }
        return relayURLs.map { relayURL in
            EndpointAddr(id: endpointID, relayUrl: relayURL, addresses: directAddresses)
        }
    }

    private func driverDidClose() async {
        guard !closed else { return }
        closed = true
        if !closing {
            terminalHealthEvent = .closedUnexpectedly
            for continuation in observers.values {
                continuation.yield(.closedUnexpectedly)
            }
        }
        onlineTask?.cancel()
        onlineTask = nil
        closureTask = nil
        await addressWatch?.stop()
        addressWatch = nil
        finishObservers()
    }

    func recordHealthEvent(_ event: CmxIrohEndpointHealthEvent) {
        guard !closing, !closed else { return }
        if event == .online {
            reachedOnline = true
        }
        for continuation in observers.values { continuation.yield(event) }
    }

    func recordAddressSnapshot(_ address: EndpointAddr) {
        guard !closing, !closed,
              let identity = try? CmxIrohLibIdentity.peerIdentity(address.id()),
              identity == peerIdentity else {
            return
        }
        observedAddressSnapshot = address
        for continuation in observers.values {
            continuation.yield(.networkChanged)
        }
    }

    private func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    private func finishObservers() {
        for continuation in observers.values { continuation.finish() }
        observers.removeAll(keepingCapacity: false)
    }

    private func restoreRelayConfigurations(
        previous: [String: CmxIrohEndpointRelayProfile.Relay],
        attempted: [String: CmxIrohEndpointRelayProfile.Relay]
    ) async -> Bool {
        var restored = true
        for relay in previous.values {
            do {
                try await driver.insertRelay(config: Self.relayConfig(relay))
            } catch {
                restored = false
            }
        }
        for addedURL in attempted.keys where previous[addedURL] == nil {
            do {
                _ = try await driver.removeRelay(url: addedURL)
            } catch {
                restored = false
            }
        }
        return restored
    }

    static func relayConfig(_ relay: CmxIrohEndpointRelayProfile.Relay) -> RelayConfig {
        RelayConfig(
            url: relay.url,
            quicPort: nil,
            authToken: relay.authenticationToken
        )
    }
}
