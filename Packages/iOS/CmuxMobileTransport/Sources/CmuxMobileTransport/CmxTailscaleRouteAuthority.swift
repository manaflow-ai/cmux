internal import CMUXMobileCore
import Darwin
import Foundation
@preconcurrency import Network
import os

struct CmxPreparedTailscaleRoute: Sendable {
    let proof: CmxTailscaleRouteProof
    let requiredInterface: NWInterface
}

protocol CmxTailscaleRouteAuthorizing: Sendable {
    func prepare(request: CmxByteTransportRequest) throws -> CmxPreparedTailscaleRoute
    func validate(proof: CmxTailscaleRouteProof, connectionPath: NWPath) throws
}

final class CmxSystemTailscaleRouteAuthority: CmxTailscaleRouteAuthorizing, @unchecked Sendable {
    static let shared = CmxSystemTailscaleRouteAuthority()

    private struct PathState: Sendable {
        var generation: UInt64 = 0
        var path: NWPath?
    }

    private struct ObservedPath: Sendable {
        let generation: UInt64
        let path: NWPath
    }

    private let pathState = OSAllocatedUnfairLock(initialState: PathState())
    private let monitor: NWPathMonitor
    private let monitorQueue = DispatchQueue(label: "dev.cmux.mobile.tailscale-route-authority")

    private init() {
        let monitor = NWPathMonitor()
        self.monitor = monitor
        let pathState = pathState
        monitor.pathUpdateHandler = { path in
            pathState.withLock { state in
                if state.path != path {
                    state.generation = Self.nextGeneration(after: state.generation)
                    state.path = path
                }
            }
        }
        monitor.start(queue: monitorQueue)
    }

    deinit {
        monitor.cancel()
    }

    func prepare(request: CmxByteTransportRequest) throws -> CmxPreparedTailscaleRoute {
        let observed = observedPath()
        let snapshot = Self.authoritySnapshot(
            generation: observed.generation,
            path: observed.path
        )
        let proof = try CmxTailscaleRouteProofValidator.prepare(
            request: request,
            snapshot: snapshot
        )
        guard let interface = observed.path.availableInterfaces.first(where: {
            $0.name == proof.interface.name && $0.index == proof.interface.index
        }) else {
            throw CmxTailscaleRouteProofError.tailscaleInterfaceUnavailable
        }
        return CmxPreparedTailscaleRoute(proof: proof, requiredInterface: interface)
    }

    func validate(proof: CmxTailscaleRouteProof, connectionPath: NWPath) throws {
        let observed = observedPath()
        let authoritySnapshot = Self.authoritySnapshot(
            generation: observed.generation,
            path: observed.path
        )
        let connectionSnapshot = Self.connectionPathSnapshot(connectionPath)
        try CmxTailscaleRouteProofValidator.validate(
            proof: proof,
            authoritySnapshot: authoritySnapshot,
            connectionPath: connectionSnapshot
        )
    }

    private func observedPath() -> ObservedPath {
        let currentPath = monitor.currentPath
        return pathState.withLock { state in
            // `currentPath` can advance before the monitor callback reaches its
            // queue. Observe that transition synchronously so the bearer gate
            // cannot use the old generation in that callback window.
            if state.path == nil || state.path != currentPath {
                state.generation = Self.nextGeneration(after: state.generation)
                state.path = currentPath
            }
            return ObservedPath(generation: state.generation, path: currentPath)
        }
    }

    private static func nextGeneration(after generation: UInt64) -> UInt64 {
        generation == .max ? 1 : generation + 1
    }

    private static func authoritySnapshot(
        generation: UInt64,
        path: NWPath
    ) -> CmxTailscaleAuthoritySnapshot {
        CmxTailscaleAuthoritySnapshot(
            generation: generation,
            pathSatisfied: path.status == .satisfied,
            availableInterfaces: Set(path.availableInterfaces.map {
                CmxNetworkInterfaceIdentity(name: $0.name, index: $0.index)
            }),
            systemInterfaces: CmxSystemInterfaceSnapshotReader.read()
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

private enum CmxSystemInterfaceSnapshotReader {
    private struct Builder {
        let identity: CmxNetworkInterfaceIdentity
        var isUp: Bool
        var isRunning: Bool
        var addresses: Set<CmxTailscaleIPAddress>
    }

    static func read() -> [CmxTailscaleInterfaceSnapshot] {
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

    private static func ipAddress(
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
