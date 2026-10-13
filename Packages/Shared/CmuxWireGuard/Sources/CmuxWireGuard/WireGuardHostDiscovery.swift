public import CmuxWireGuardPairing
public import Foundation
import Network
import os

/// Finds cmux Macs on the local network. Each Mac advertises
/// `_cmux-wg._udp` with TXT `id=<host id>` and `hk=<public key>`.
public struct WireGuardHostDiscovery: Sendable {
    public static let serviceType = "_cmux-wg._udp"

    /// A Mac seen on the network, resolved to one UDP endpoint.
    public struct Host: Hashable, Sendable {
        public var name: String
        public var hostID: String
        public var hostKey: WireGuardKey?
        /// "ip:port" or "[ipv6]:port".
        public var endpoint: String
    }

    public init() {}

    /// Endpoints for the paired Mac with `hostID` (the first that resolves).
    public func endpoints(hostID: String, timeout: Duration = .seconds(4)) async -> [String] {
        let search = DiscoverySearch(hostID: hostID)
        return await search.run(timeout: timeout).map(\.endpoint)
    }

    /// Every cmux Mac that resolves within `timeout`.
    public func hosts(timeout: Duration = .seconds(3)) async -> [Host] {
        await DiscoverySearch(hostID: nil).run(timeout: timeout)
    }
}

/// One browse. With a host id it ends at the first resolution of that Mac;
/// without one it collects every Mac until the deadline.
private final class DiscoverySearch: Sendable {
    private struct State {
        var continuation: CheckedContinuation<[WireGuardHostDiscovery.Host], Never>?
        var browser: NWBrowser?
        var connections: [NWConnection] = []
        var found: [WireGuardHostDiscovery.Host] = []
        var resolving: Set<String> = []
        var done = false
    }

    private let hostID: String?
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(label: "cmux.wireguard.discovery")

    init(hostID: String?) {
        self.hostID = hostID
    }

    func run(timeout: Duration) async -> [WireGuardHostDiscovery.Host] {
        // task-owner: the one-shot deadline for this search; finish() is idempotent
        let deadline = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.finish()
        }
        defer { deadline.cancel() }
        return await withCheckedContinuation { continuation in
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: WireGuardHostDiscovery.serviceType, domain: nil),
                                    using: .udp)
            let proceed = state.withLock { state -> Bool in
                guard !state.done else { return false }
                state.continuation = continuation
                state.browser = browser
                return true
            }
            guard proceed else { return continuation.resume(returning: []) }
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                for result in results { self?.consider(result) }
            }
            browser.start(queue: queue)
        }
    }

    private func consider(_ result: NWBrowser.Result) {
        guard case .bonjour(let txt) = result.metadata, let id = txt["id"], hostID == nil || id == hostID,
              case .service(let name, _, _, _) = result.endpoint else { return }
        let fresh = state.withLock { state in state.resolving.insert(id).inserted }
        guard fresh else { return }
        let key = txt["hk"].flatMap(WireGuardKey.init(base64:))
        // IPv4: a resolved link-local IPv6 address is unusable without its
        // scope, and every Mac on the LAN has an IPv4 address.
        let parameters = NWParameters.udp
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let connection = NWConnection(to: result.endpoint, using: parameters)
        state.withLock { $0.connections.append(connection) }
        connection.stateUpdateHandler = { [weak self, weak connection] update in
            guard case .ready = update, let self, let connection,
                  case .hostPort(let host, let port)? = connection.currentPath?.remoteEndpoint else { return }
            var address = "\(host)"
            if let percent = address.firstIndex(of: "%") { address = String(address[..<percent]) }
            let endpoint = address.contains(":") ? "[\(address)]:\(port.rawValue)" : "\(address):\(port.rawValue)"
            self.found(WireGuardHostDiscovery.Host(name: name, hostID: id, hostKey: key, endpoint: endpoint))
        }
        connection.start(queue: queue)
    }

    private func found(_ host: WireGuardHostDiscovery.Host) {
        state.withLock { $0.found.append(host) }
        if hostID != nil { finish() }
    }

    func finish() {
        let (continuation, browser, connections, found) = state.withLock { state in
            state.done = true
            defer {
                state.continuation = nil
                state.browser = nil
                state.connections = []
            }
            return (state.continuation, state.browser, state.connections, state.found)
        }
        continuation?.resume(returning: found)
        browser?.cancel()
        for connection in connections { connection.cancel() }
    }
}
