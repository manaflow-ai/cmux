import CMUXMobileCore
import Darwin
import Foundation

struct MobileHostRouteSnapshot: Sendable {
    let routes: [CmxAttachRoute]

    var payload: [[String: Any]] {
        routes.map(\.mobileHostJSONObject)
    }
}

final class MobileRouteResolver: @unchecked Sendable {
    private static let tailscaleRouteCacheTTL: TimeInterval = 30

    private let cacheLock = NSLock()
    private var cachedResolvedTailscaleHosts: [String] = []
    private var cachedResolvedTailscaleHostsUpdatedAt: Date?
    private var tailscaleRefreshTask: Task<[String], Never>?
    private var tailscaleRefreshCallbacks: [@Sendable ([String]) -> Void] = []
    /// Bumped by ``invalidateResolvedTailscaleHostCache()``. A resolution
    /// started before an invalidation must not write its (old-network) hosts
    /// into the cache after it, so every store is guarded by the generation
    /// captured when its refresh task was created.
    private var cacheGeneration = 0

    func routes(
        port: Int,
        manualHost: String? = nil,
        now: Date = Date(),
        immediateHosts: () -> [String] = { MobileRouteResolver.tailscaleRouteHosts(resolveDNS: false) }
    ) -> MobileHostRouteSnapshot {
        refreshTailscaleRoutes()
        let cachedHosts = resolvedTailscaleRouteHostsFromCache(now: now) ?? []
        return routes(
            port: port,
            tailscaleHosts: Self.deduplicatedHosts(cachedHosts + immediateHosts()),
            manualHost: manualHost
        )
    }

    func routesResolvingTailscaleDNS(
        port: Int,
        manualHost: String? = nil,
        resolveHosts: @escaping @Sendable () -> [String] = { MobileRouteResolver.tailscaleRouteHosts(resolveDNS: true) },
        now: Date = Date()
    ) async -> MobileHostRouteSnapshot {
        let hosts = await resolvedTailscaleRouteHosts(resolveHosts: resolveHosts, now: now)
        return routes(port: port, tailscaleHosts: hosts, manualHost: manualHost)
    }

    /// Drop the resolved-host cache and orphan any in-flight resolution.
    ///
    /// Called when the Mac's network path changes: the cached hosts (and any
    /// resolution that started on the old path) describe the previous network,
    /// so serving them for the rest of their TTL would advertise routes the
    /// Mac is no longer reachable on. The next ``routes(port:now:immediateHosts:)``
    /// or ``refreshTailscaleRoutes(resolveHosts:onResolvedHosts:)`` call starts
    /// a fresh resolution; an orphaned in-flight task's result is discarded by
    /// the generation guard in ``storeResolvedTailscaleHosts(_:now:generation:)``.
    func invalidateResolvedTailscaleHostCache() {
        cacheLock.lock()
        cachedResolvedTailscaleHosts = []
        cachedResolvedTailscaleHostsUpdatedAt = nil
        tailscaleRefreshTask = nil
        cacheGeneration &+= 1
        cacheLock.unlock()
    }

    func routes(
        port: Int,
        tailscaleHosts: [String],
        manualHost: String? = nil
    ) -> MobileHostRouteSnapshot {
        var resolved: [CmxAttachRoute] = []

        if Self.includesDebugLoopbackRoute {
            if let debugRoute = try? CmxAttachRoute(
                id: CmxAttachTransportKind.debugLoopback.rawValue,
                kind: .debugLoopback,
                endpoint: .hostPort(host: "127.0.0.1", port: port),
                priority: 0
            ) {
                resolved.append(debugRoute)
            }
        }

        for (index, tailscaleHost) in tailscaleHosts.enumerated() {
            let id = index == 0
                ? CmxAttachTransportKind.tailscale.rawValue
                : "\(CmxAttachTransportKind.tailscale.rawValue)_\(index + 1)"
            if let tailscaleRoute = try? CmxAttachRoute(
                id: id,
                kind: .tailscale,
                endpoint: .hostPort(host: tailscaleHost, port: port),
                priority: 10 + (index * 10)
            ) {
                resolved.append(tailscaleRoute)
            }
        }

        if let manualHost = manualHost.flatMap({ CmxManualHost($0)?.rawValue }) {
            let manualPriority = 10 + (tailscaleHosts.count * 10)
            if let manualRoute = try? CmxAttachRoute(
                id: CmxAttachTransportKind.manualHost.rawValue,
                kind: .manualHost,
                endpoint: .hostPort(host: manualHost, port: port),
                priority: manualPriority
            ) {
                resolved.append(manualRoute)
            }
        }

        return MobileHostRouteSnapshot(routes: resolved)
    }

    private struct TailscaleAddressCandidate {
        let interfaceName: String
        let address: String
        let dnsName: String?
    }

    func refreshTailscaleRoutes(
        resolveHosts: @escaping @Sendable () -> [String] = { MobileRouteResolver.tailscaleRouteHosts(resolveDNS: true) },
        onResolvedHosts: (@Sendable ([String]) -> Void)? = nil
    ) {
        cacheLock.lock()
        guard !hasFreshResolvedTailscaleHostsLocked(now: Date()) else {
            let cachedHosts = cachedResolvedTailscaleHosts
            cacheLock.unlock()
            onResolvedHosts?(cachedHosts)
            return
        }
        if let onResolvedHosts {
            tailscaleRefreshCallbacks.append(onResolvedHosts)
        }
        _ = tailscaleRefreshTaskLocked(resolveHosts: resolveHosts)
        cacheLock.unlock()
    }

    private static var includesDebugLoopbackRoute: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    private func resolvedTailscaleRouteHosts(
        resolveHosts: @escaping @Sendable () -> [String],
        now: Date
    ) async -> [String] {
        if let cachedHosts = resolvedTailscaleRouteHostsFromCache(now: now) {
            return cachedHosts
        }
        let (task, generation) = tailscaleRefreshTask(resolveHosts: resolveHosts)
        let hosts = await task.value
        storeResolvedTailscaleHosts(hosts, generation: generation)
        return hosts
    }

    private func resolvedTailscaleRouteHostsFromCache(now: Date) -> [String]? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard hasFreshResolvedTailscaleHostsLocked(now: now) else {
            return nil
        }
        return cachedResolvedTailscaleHosts
    }

    private func hasFreshResolvedTailscaleHostsLocked(now: Date) -> Bool {
        guard let updatedAt = cachedResolvedTailscaleHostsUpdatedAt else {
            return false
        }
        let cachedHosts = cachedResolvedTailscaleHosts
        return !cachedHosts.isEmpty && now.timeIntervalSince(updatedAt) <= Self.tailscaleRouteCacheTTL
    }

    private func tailscaleRefreshTask(
        resolveHosts: @escaping @Sendable () -> [String]
    ) -> (task: Task<[String], Never>, generation: Int) {
        cacheLock.lock()
        let task = tailscaleRefreshTaskLocked(resolveHosts: resolveHosts)
        cacheLock.unlock()
        return task
    }

    private func tailscaleRefreshTaskLocked(
        resolveHosts: @escaping @Sendable () -> [String]
    ) -> (task: Task<[String], Never>, generation: Int) {
        let generation = cacheGeneration
        if let tailscaleRefreshTask {
            return (tailscaleRefreshTask, generation)
        }
        let task = Task.detached(priority: .utility) {
            resolveHosts()
        }
        tailscaleRefreshTask = task
        Task.detached { [weak self, task] in
            let hosts = await task.value
            self?.storeResolvedTailscaleHosts(hosts, generation: generation)
        }
        return (task, generation)
    }

    private func storeResolvedTailscaleHosts(_ hosts: [String], now: Date = Date(), generation: Int) {
        let callbacks = storeResolvedTailscaleHostsAndTakeCallbacks(hosts, now: now, generation: generation)
        for callback in callbacks {
            callback(hosts)
        }
    }

    private func storeResolvedTailscaleHostsAndTakeCallbacks(
        _ hosts: [String],
        now: Date,
        generation: Int
    ) -> [@Sendable ([String]) -> Void] {
        let hasResolvedMagicDNS = hosts.contains { Self.isTailscaleDNSName($0) }
        cacheLock.lock()
        guard generation == cacheGeneration else {
            // This resolution raced an invalidation (the network changed while
            // it was in flight): its hosts describe the old path. Discard them
            // and leave the queued callbacks for the fresh refresh the
            // invalidating caller starts.
            cacheLock.unlock()
            return []
        }
        cachedResolvedTailscaleHosts = hosts
        cachedResolvedTailscaleHostsUpdatedAt = hasResolvedMagicDNS ? now : nil
        tailscaleRefreshTask = nil
        let callbacks = tailscaleRefreshCallbacks
        tailscaleRefreshCallbacks.removeAll()
        cacheLock.unlock()
        return callbacks
    }

    private static func tailscaleRouteHosts(resolveDNS: Bool) -> [String] {
        guard let candidate = preferredTailscaleAddressCandidate(resolveDNS: resolveDNS) else {
            return []
        }

        var hosts: [String] = []
        if let dnsName = candidate.dnsName {
            hosts.append(dnsName)
        }
        hosts.append(candidate.address)

        return deduplicatedHosts(hosts)
    }

    private static func deduplicatedHosts(_ hosts: [String]) -> [String] {
        var seen = Set<String>()
        return hosts.filter { host in
            let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty, !seen.contains(normalized) else {
                return false
            }
            seen.insert(normalized)
            return true
        }
    }

    private static func preferredTailscaleAddressCandidate(resolveDNS: Bool) -> TailscaleAddressCandidate? {
        let candidates = tailscaleAddressCandidates(resolveDNS: resolveDNS)
        if let match = candidates.first(where: { isTailscaleDNSName($0.dnsName) }) {
            return match
        }
        return candidates.first
    }

    private static func tailscaleAddressCandidates(resolveDNS: Bool) -> [TailscaleAddressCandidate] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let firstInterface = interfaces else {
            return []
        }
        defer { freeifaddrs(interfaces) }

        var tailscaleInterfaceNames = Set<String>()
        var cgnatCandidates: [TailscaleAddressCandidate] = []
        var pointer: UnsafeMutablePointer<ifaddrs>? = firstInterface
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }

            guard let nameCString = current.pointee.ifa_name else {
                continue
            }
            let interfaceName = String(cString: nameCString)
            let flags = Int32(current.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else {
                continue
            }
            guard let address = current.pointee.ifa_addr,
                  let candidate = numericHost(for: address) else {
                continue
            }

            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                if isTailscaleCGNAT(candidate) {
                    cgnatCandidates.append(
                        TailscaleAddressCandidate(
                            interfaceName: interfaceName,
                            address: candidate,
                            dnsName: resolveDNS ? reverseDNSHost(for: address) : nil
                        )
                    )
                }
            case AF_INET6:
                if isTailscaleIPv6ULA(candidate) || isTailscaleInterfaceName(interfaceName) {
                    tailscaleInterfaceNames.insert(interfaceName)
                }
            default:
                break
            }
        }

        let confirmedCandidates = cgnatCandidates.filter { candidate in
            tailscaleInterfaceNames.contains(candidate.interfaceName) ||
                isTailscaleInterfaceName(candidate.interfaceName)
        }
        return confirmedCandidates.isEmpty ? cgnatCandidates : confirmedCandidates
    }

    private static func numericHost(for address: UnsafeMutablePointer<sockaddr>) -> String? {
        switch Int32(address.pointee.sa_family) {
        case AF_INET, AF_INET6:
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            return result == 0 ? String(cString: host) : nil
        default:
            return nil
        }
    }

    private static func reverseDNSHost(for address: UnsafeMutablePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(
            address,
            socklen_t(address.pointee.sa_len),
            &host,
            socklen_t(host.count),
            nil,
            0,
            NI_NAMEREQD
        )
        guard result == 0 else {
            return nil
        }
        let name = String(cString: host)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        return isTailscaleDNSName(name) ? name : nil
    }

    private static func isTailscaleCGNAT(_ ipAddress: String) -> Bool {
        let octets = ipAddress.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else {
            return false
        }
        return octets[0] == 100 && (64...127).contains(octets[1])
    }

    private static func isTailscaleIPv6ULA(_ ipAddress: String) -> Bool {
        ipAddress.lowercased().hasPrefix("fd7a:115c:a1e0:")
    }

    private static func isTailscaleInterfaceName(_ name: String) -> Bool {
        name.localizedCaseInsensitiveContains("tailscale")
    }

    private static func isTailscaleDNSName(_ name: String?) -> Bool {
        guard let name else {
            return false
        }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasSuffix(".ts.net")
    }
}

extension CmxAttachRoute {
    var mobileHostJSONObject: [String: Any] {
        var endpointPayload: [String: Any] = [:]
        switch endpoint {
        case let .hostPort(host, port):
            endpointPayload = [
                "type": "host_port",
                "host": host,
                "port": port
            ]
        case let .peer(id, relayHint, directAddrs, relayURL):
            endpointPayload = [
                "type": "peer",
                "id": id,
                "relay_hint": relayHint ?? NSNull(),
            ]
            if !directAddrs.isEmpty {
                endpointPayload["direct_addrs"] = directAddrs
            }
            if let relayURL {
                endpointPayload["relay_url"] = relayURL
            }
        case let .url(url):
            endpointPayload = [
                "type": "url",
                "url": url
            ]
        }

        return [
            "id": id,
            "kind": kind.rawValue,
            "endpoint": endpointPayload,
            "priority": priority
        ]
    }
}
