internal import CMUXMobileCore
import CmuxMobileDiagnostics
import Darwin
import Foundation
@preconcurrency import Network
import os

struct CmxPreparedTailscaleRoute: Sendable {
    let proof: CmxTailscaleRouteProof
    let requiredInterface: NWInterface
}

protocol CmxTailscaleRouteAuthorizing: Sendable {
    func prepare(request: CmxByteTransportRequest) async throws -> CmxPreparedTailscaleRoute
    func validate(
        proof: CmxTailscaleRouteProof,
        connectionPath: NWPath,
        phase: CmxTailscaleRouteValidationPhase
    ) async throws
}

/// Platform wiring for ``CmxTailscaleRouteReadiness``: converts every
/// `NWPathMonitor` callback into a sequence-stamped observation and forwards
/// it to the readiness actor, which owns all waiting, retry, and deadline
/// state. `currentPath` is never treated as authoritative on its own; the
/// monitor's startup snapshot only reaches the readiness actor as an
/// observation like any other, so preparation gates on real callbacks.
final class CmxSystemTailscaleRouteAuthority: CmxTailscaleRouteAuthorizing, Sendable {
    /// How long preparation waits for the tunnel to become provable. Chosen to
    /// cover Tailscale's tunnel bring-up after a QR scan while staying under
    /// the RPC layer's whole-request deadline, so an unusable tunnel surfaces
    /// as the actionable Tailscale failure rather than a generic timeout.
    static let defaultReadinessDeadline: Duration = .seconds(10)

    private let monitor: NWPathMonitor
    private let readiness: CmxTailscaleRouteReadiness<NWInterface>
    private let observationSequence: OSAllocatedUnfairLock<UInt64>

    init(
        clock: any Clock<Duration> = ContinuousClock(),
        readinessDeadline: Duration = CmxSystemTailscaleRouteAuthority.defaultReadinessDeadline
    ) {
        let readiness = CmxTailscaleRouteReadiness<NWInterface>(
            clock: clock,
            readinessDeadline: readinessDeadline
        )
        let sequence = OSAllocatedUnfairLock<UInt64>(initialState: 0)
        let monitor = NWPathMonitor()
        self.readiness = readiness
        self.observationSequence = sequence
        self.monitor = monitor
        // The handler captures only the readiness actor and the sequence lock
        // (not self), so the authority can deinit and cancel the monitor.
        monitor.pathUpdateHandler = { path in
            let observation = Self.observation(
                sequence: Self.nextSequence(sequence),
                path: path
            )
            Task { await readiness.ingest(observation) }
        }
        // Network.framework requires a callback queue; the serial queue orders
        // sequence stamping with capture, and the readiness actor drops any
        // observation that arrives out of order after the hop.
        monitor.start(
            queue: DispatchQueue(
                label: "dev.cmux.mobile.tailscale-route-authority"
            )
        )
    }

    deinit {
        monitor.cancel()
    }

    func prepare(request: CmxByteTransportRequest) async throws -> CmxPreparedTailscaleRoute {
        MobileDebugLog.shared.append(
            "tailscale.prepare.begin route=\(request.route.kind.rawValue)"
        )
        let ready = try await readiness.prepare(request: request)
        return CmxPreparedTailscaleRoute(
            proof: ready.proof,
            requiredInterface: ready.interface
        )
    }

    func validate(
        proof: CmxTailscaleRouteProof,
        connectionPath: NWPath,
        phase: CmxTailscaleRouteValidationPhase
    ) async throws {
        // `currentPath` can advance before the queued callback task lands on
        // the readiness actor. Ingest a fresh capture first so the write
        // boundary can never validate against a stale observation.
        await readiness.ingest(
            Self.observation(
                sequence: Self.nextSequence(observationSequence),
                path: monitor.currentPath
            )
        )
        try await readiness.validate(
            proof: proof,
            connectionPath: Self.connectionPathSnapshot(connectionPath),
            phase: phase
        )
    }

    private static func nextSequence(
        _ lock: OSAllocatedUnfairLock<UInt64>
    ) -> UInt64 {
        lock.withLock { sequence in
            sequence += 1
            return sequence
        }
    }

    private static func observation(
        sequence: UInt64,
        path: NWPath
    ) -> CmxTailscalePathObservation<NWInterface> {
        CmxTailscalePathObservation(
            sequence: sequence,
            pathSatisfied: path.status == .satisfied,
            interfaces: Dictionary(
                path.availableInterfaces.map {
                    (CmxNetworkInterfaceIdentity(name: $0.name, index: $0.index), $0)
                },
                uniquingKeysWith: { first, _ in first }
            ),
            systemInterfaces: CmxSystemInterfaceSnapshotReader().read()
        )
    }

    private static func connectionPathSnapshot(
        _ path: NWPath
    ) -> CmxTailscaleConnectionPathSnapshot {
        let localAddress: CmxTailscaleIPAddress?
        if let localEndpoint = path.localEndpoint {
            localAddress = address(from: localEndpoint)
        } else {
            localAddress = nil
        }

        let remoteAddress: CmxTailscaleIPAddress?
        let remotePort: Int?
        if let remoteEndpoint = path.remoteEndpoint,
           case let .hostPort(_, port) = remoteEndpoint {
            remoteAddress = address(from: remoteEndpoint)
            remotePort = Int(port.rawValue)
        } else {
            remoteAddress = nil
            remotePort = nil
        }

        return CmxTailscaleConnectionPathSnapshot(
            isSatisfied: path.status == .satisfied,
            availableInterfaces: Set(path.availableInterfaces.map {
                CmxNetworkInterfaceIdentity(name: $0.name, index: $0.index)
            }),
            localAddress: localAddress,
            remoteAddress: remoteAddress,
            remotePort: remotePort
        )
    }

    private static func address(from endpoint: NWEndpoint) -> CmxTailscaleIPAddress? {
        guard case let .hostPort(host, _) = endpoint else { return nil }
        switch host {
        case let .ipv4(address):
            return CmxTailscaleIPAddress(family: .ipv4, bytes: address.rawValue)
        case let .ipv6(address):
            return CmxTailscaleIPAddress(family: .ipv6, bytes: address.rawValue)
        case .name:
            return nil
        @unknown default:
            return nil
        }
    }
}

private struct CmxSystemInterfaceSnapshotReader {
    private struct Builder {
        let identity: CmxNetworkInterfaceIdentity
        var isUp: Bool
        var isRunning: Bool
        var addresses: Set<CmxTailscaleIPAddress>
    }

    func read() -> [CmxTailscaleInterfaceSnapshot] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else {
            return []
        }
        defer { freeifaddrs(interfaces) }

        var builders: [CmxNetworkInterfaceIdentity: Builder] = [:]
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            guard let nameCString = current.pointee.ifa_name else { continue }
            let name = String(cString: nameCString)
            let index = Int(if_nametoindex(nameCString))
            guard index > 0 else { continue }

            let identity = CmxNetworkInterfaceIdentity(name: name, index: index)
            let flags = current.pointee.ifa_flags
            var builder = builders[identity] ?? Builder(
                identity: identity,
                isUp: false,
                isRunning: false,
                addresses: []
            )
            builder.isUp = builder.isUp || (flags & UInt32(IFF_UP)) != 0
            builder.isRunning = builder.isRunning || (flags & UInt32(IFF_RUNNING)) != 0
            if let address = current.pointee.ifa_addr,
               let ipAddress = ipAddress(from: address) {
                builder.addresses.insert(ipAddress)
            }
            builders[identity] = builder
        }

        return builders.values.map { builder in
            CmxTailscaleInterfaceSnapshot(
                identity: builder.identity,
                isUp: builder.isUp,
                isRunning: builder.isRunning,
                addresses: builder.addresses
            )
        }
    }

    private func ipAddress(
        from address: UnsafeMutablePointer<sockaddr>
    ) -> CmxTailscaleIPAddress? {
        switch Int32(address.pointee.sa_family) {
        case AF_INET:
            var value = UnsafeRawPointer(address)
                .assumingMemoryBound(to: sockaddr_in.self)
                .pointee
                .sin_addr
            let bytes = withUnsafeBytes(of: &value) { Data($0) }
            return CmxTailscaleIPAddress(family: .ipv4, bytes: bytes)
        case AF_INET6:
            var value = UnsafeRawPointer(address)
                .assumingMemoryBound(to: sockaddr_in6.self)
                .pointee
                .sin6_addr
            let bytes = withUnsafeBytes(of: &value) { Data($0) }
            return CmxTailscaleIPAddress(family: .ipv6, bytes: bytes)
        default:
            return nil
        }
    }
}
