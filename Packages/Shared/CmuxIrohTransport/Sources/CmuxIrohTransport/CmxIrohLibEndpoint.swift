import CMUXMobileCore
import Foundation
import IrohLib

actor CmxIrohLibEndpoint: CmxIrohEndpoint {
    private let driver: Endpoint
    private let peerIdentity: CmxIrohPeerIdentity
    private let alpns: Set<Data>
    private let managedRelayURLs: Set<String>
    private var relayConfigurations: [String: CmxIrohRelayConfiguration]
    private var networkWatch: WatchHandle?
    private var addressWatch: WatchHandle?
    private var onlineTask: Task<Void, Never>?
    private var closureTask: Task<Void, Never>?
    private var closing = false
    private var closed = false
    private var terminalHealthEvent: CmxIrohEndpointHealthEvent?
    private var observers: [
        UUID: AsyncStream<CmxIrohEndpointHealthEvent>.Continuation
    ] = [:]

    init(
        driver: Endpoint,
        identity: CmxIrohPeerIdentity,
        configuration: CmxIrohEndpointConfiguration
    ) {
        self.driver = driver
        peerIdentity = identity
        alpns = Set(configuration.alpns)
        managedRelayURLs = configuration.managedRelayURLs
        relayConfigurations = Dictionary(
            uniqueKeysWithValues: configuration.relays.map { ($0.url, $0) }
        )
    }

    func startMonitoring() {
        guard networkWatch == nil, addressWatch == nil, closureTask == nil else { return }
        networkWatch = driver.watchNetworkChange(
            callback: CmxIrohLibNetworkChangeCallback { [weak self] in
                await self?.publish(.networkChanged)
            }
        )
        addressWatch = driver.watchAddr(
            callback: CmxIrohLibAddressChangeCallback { [weak self] in
                await self?.publish(.networkChanged)
            }
        )
        let driver = driver
        onlineTask = Task { [weak self] in
            await driver.online()
            guard !Task.isCancelled else { return }
            await self?.publish(.online)
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
        let address = driver.addr()
        let now = Date()
        let expiresAt = now.addingTimeInterval(CmxIrohPathHint.maximumPrivateHintTTL)
        var hints: [CmxIrohPathHint] = []
        if let relayURL = address.relayUrl(), managedRelayURLs.contains(relayURL),
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
        return CmxIrohEndpointAddress(identity: peerIdentity, pathHints: hints)
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
        guard relays.count <= 8 else {
            throw CmxIrohEndpointConfigurationError.tooManyRelays(relays.count)
        }
        var next: [String: CmxIrohRelayConfiguration] = [:]
        let now = Date()
        for relay in relays {
            guard managedRelayURLs.contains(relay.url) else {
                throw CmxIrohLibError.unmanagedRelayURL(relay.url)
            }
            guard relay.expiresAt > now else {
                throw CmxIrohLibError.expiredRelayCredential(relay.url)
            }
            guard next.updateValue(relay, forKey: relay.url) == nil else {
                throw CmxIrohEndpointConfigurationError.duplicateRelayURL(relay.url)
            }
        }
        for relay in relays {
            try await driver.insertRelay(config: Self.relayConfig(relay))
        }
        for staleURL in relayConfigurations.keys where next[staleURL] == nil {
            _ = try await driver.removeRelay(url: staleURL)
        }
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
        await networkWatch?.stop()
        await addressWatch?.stop()
        networkWatch = nil
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
                guard managedRelayURLs.contains(hint.value) else {
                    throw CmxIrohLibError.unmanagedRelayURL(hint.value)
                }
                if observedRelayURLs.insert(hint.value).inserted {
                    relayURLs.append(hint.value)
                }
            case .directAddress:
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
        await networkWatch?.stop()
        await addressWatch?.stop()
        networkWatch = nil
        addressWatch = nil
        finishObservers()
    }

    private func publish(_ event: CmxIrohEndpointHealthEvent) {
        guard !closing, !closed else { return }
        for continuation in observers.values { continuation.yield(event) }
    }

    private func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    private func finishObservers() {
        for continuation in observers.values { continuation.finish() }
        observers.removeAll(keepingCapacity: false)
    }

    static func relayConfig(_ relay: CmxIrohRelayConfiguration) -> RelayConfig {
        RelayConfig(url: relay.url, quicPort: nil, authToken: relay.token)
    }
}
