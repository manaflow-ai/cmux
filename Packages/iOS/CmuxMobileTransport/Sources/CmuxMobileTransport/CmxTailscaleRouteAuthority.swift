internal import CMUXMobileCore
import CmuxMobileDiagnostics
import Darwin
import Foundation
@preconcurrency import Network

struct CmxPreparedTailscaleRoute: Sendable {
    let proof: CmxTailscaleRouteProof
    let requiredInterface: NWInterface
}

protocol CmxTailscaleRouteAuthorizing: Sendable {
    func prepare(request: CmxByteTransportRequest) async throws -> CmxPreparedTailscaleRoute
    func waitForNextPathUpdate() async
    func validate(proof: CmxTailscaleRouteProof, connectionPath: NWPath) async throws
}

extension CmxTailscaleRouteAuthorizing {
    func waitForNextPathUpdate() async {}
}

actor CmxSystemTailscaleRouteAuthority: CmxTailscaleRouteAuthorizing {
    private struct PathState: Sendable {
        var generation: UInt64 = 0
        var path: NWPath?
    }

    private struct ObservedPath: Sendable {
        let generation: UInt64
        let path: NWPath
    }

    private var pathState = PathState()
    private var hasReceivedInitialPathUpdate = false
    private var initialPathWaiters: [CheckedContinuation<Void, Never>] = []
    private let pathUpdateContinuation: AsyncStream<Void>.Continuation
    private let pathUpdateStream: AsyncStream<Void>
    private let monitor: NWPathMonitor

    init() {
        let monitor = NWPathMonitor()
        self.monitor = monitor
        let pathUpdates = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.pathUpdateContinuation = pathUpdates.continuation
        self.pathUpdateStream = pathUpdates.stream
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            Task { await self.observe(path) }
        }
        // Network.framework requires a callback queue. The callback immediately
        // enters this actor, which is the sole owner of mutable path state.
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
        // `currentPath` is not authoritative until NWPathMonitor has delivered
        // its first callback. Pairing can begin immediately after the scanner
        // returns, so gate the first proof on that callback instead of treating
        // the monitor's startup snapshot as a real Tailscale outage.
        await waitForInitialPathUpdate()
        while true {
            let observed = observedPath()
            let snapshot = Self.authoritySnapshot(
                generation: observed.generation,
                path: observed.path
            )
            MobileDebugLog.shared.append(Self.logLine("tailscale.prepare.snapshot", snapshot: snapshot))
            let proof: CmxTailscaleRouteProof
            do {
                proof = try CmxTailscaleRouteProofValidator().prepare(
                    request: request,
                    snapshot: snapshot
                )
            } catch let error as CmxTailscaleRouteProofError
                where error.isTransientReadinessFailure
            {
                MobileDebugLog.shared.append(
                    "tailscale.prepare.proof_failed error=\(String(describing: error)); waiting_for_path_update=true"
                )
                await waitForNextPathUpdate()
                continue
            } catch {
                MobileDebugLog.shared.append(
                    "tailscale.prepare.proof_failed error=\(String(describing: error))"
                )
                throw error
            }
            guard let interface = observed.path.availableInterfaces.first(where: {
                $0.name == proof.interface.name && $0.index == proof.interface.index
            }) else {
                MobileDebugLog.shared.append(
                    "tailscale.prepare.interface_failed proof_interface=\(proof.interface.name):\(proof.interface.index) snapshot_interfaces=\(Self.interfaceNames(observed.path)); waiting_for_path_update=true"
                )
                await waitForNextPathUpdate()
                continue
            }
            MobileDebugLog.shared.append(
                "tailscale.prepare.success interface=\(proof.interface.name):\(proof.interface.index) generation=\(proof.generation)"
            )
            return CmxPreparedTailscaleRoute(proof: proof, requiredInterface: interface)
        }
    }

    func waitForNextPathUpdate() async {
        var iterator = pathUpdateStream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func validate(proof: CmxTailscaleRouteProof, connectionPath: NWPath) throws {
        let observed = observedPath()
        let authoritySnapshot = Self.authoritySnapshot(
            generation: observed.generation,
            path: observed.path
        )
        let connectionSnapshot = Self.connectionPathSnapshot(connectionPath)
        try CmxTailscaleRouteProofValidator().validate(
            proof: proof,
            authoritySnapshot: authoritySnapshot,
            connectionPath: connectionSnapshot
        )
    }

    private func observedPath() -> ObservedPath {
        let currentPath = monitor.currentPath
        // `currentPath` can advance before the callback reaches this actor.
        // Record that transition synchronously so a write cannot reuse the old
        // authority generation during that callback window.
        if pathState.path == nil || pathState.path != currentPath {
            pathState.generation = Self.nextGeneration(after: pathState.generation)
            pathState.path = currentPath
        }
        return ObservedPath(generation: pathState.generation, path: currentPath)
    }

    private func observe(_ path: NWPath) {
        let pathChanged = pathState.path != path
        if pathChanged {
            pathState.generation = Self.nextGeneration(after: pathState.generation)
            pathState.path = path
            let snapshot = Self.authoritySnapshot(
                generation: pathState.generation,
                path: path
            )
            MobileDebugLog.shared.append(Self.logLine("tailscale.path_update", snapshot: snapshot))
        }
        let wasInitialPathUpdate = !hasReceivedInitialPathUpdate
        guard wasInitialPathUpdate else {
            // `observedPath()` may have read the monitor's newer snapshot
            // before this callback reached the actor, so wake on every
            // post-initial callback rather than relying on path equality.
            pathUpdateContinuation.yield(())
            return
        }
        hasReceivedInitialPathUpdate = true
        let waiters = initialPathWaiters
        initialPathWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
    }

    private func waitForInitialPathUpdate() async {
        guard !hasReceivedInitialPathUpdate else { return }
        await withCheckedContinuation { continuation in
            if hasReceivedInitialPathUpdate {
                continuation.resume()
            } else {
                initialPathWaiters.append(continuation)
            }
        }
    }

    private static func logLine(
        _ prefix: String,
        snapshot: CmxTailscaleAuthoritySnapshot
    ) -> String {
        let interfaces = snapshot.systemInterfaces.map { interface in
            "\(interface.identity.name):\(interface.identity.index),up=\(interface.isUp),running=\(interface.isRunning),tailnet_addrs=\(interface.tailnetAddresses.count)"
        }.sorted().joined(separator: ";")
        return "\(prefix) generation=\(snapshot.generation) path_satisfied=\(snapshot.pathSatisfied) available_interfaces=\(interfaceNames(snapshot.availableInterfaces)) system_interfaces=\(interfaces)"
    }

    private static func interfaceNames(_ interfaces: Set<CmxNetworkInterfaceIdentity>) -> String {
        interfaces.map { "\($0.name):\($0.index)" }.sorted().joined(separator: ",")
    }

    private static func interfaceNames(_ path: NWPath) -> String {
        interfaceNames(Set(path.availableInterfaces.map {
            CmxNetworkInterfaceIdentity(name: $0.name, index: $0.index)
        }))
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
