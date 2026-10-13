public import Foundation
import Network
import os

/// Finds a paired Mac on the local network by its host id (the Mac
/// advertises `_cmux-wg._udp` with TXT `id=<host id>`), for when every saved
/// endpoint went stale. Returns "ip:port" endpoints, IPv4 first.
public struct WireGuardHostDiscovery: Sendable {
    public static let serviceType = "_cmux-wg._udp"

    public init() {}

    public func endpoints(hostID: String, timeout: Duration = .seconds(4)) async -> [String] {
        let search = DiscoverySearch(hostID: hostID)
        return await withTaskGroup(of: [String].self) { group in
            group.addTask { await search.run() }
            group.addTask {
                // A one-shot deadline for the whole search.
                try? await Task.sleep(for: timeout)
                search.finish()
                return []
            }
            var found: [String] = []
            for await result in group where !result.isEmpty {
                found = result
                break
            }
            search.finish()
            group.cancelAll()
            return found
        }
    }
}

/// One browse: matching services are resolved by opening a UDP path to them
/// and reading the remote address; the first resolution ends the search.
private final class DiscoverySearch: Sendable {
    private struct State {
        var continuation: CheckedContinuation<[String], Never>?
        var browser: NWBrowser?
        var connections: [NWConnection] = []
        var done = false
    }

    private let hostID: String
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(label: "cmux.wireguard.discovery")

    init(hostID: String) {
        self.hostID = hostID
    }

    func run() async -> [String] {
        await withCheckedContinuation { continuation in
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
                guard let self else { return }
                for result in results where self.matches(result) { self.resolve(result.endpoint) }
            }
            browser.start(queue: queue)
        }
    }

    private func matches(_ result: NWBrowser.Result) -> Bool {
        guard case .bonjour(let txt) = result.metadata else { return false }
        return txt["id"] == hostID
    }

    private func resolve(_ endpoint: NWEndpoint) {
        let connection = NWConnection(to: endpoint, using: .udp)
        state.withLock { $0.connections.append(connection) }
        connection.stateUpdateHandler = { [weak self, weak connection] update in
            guard case .ready = update, let self, let connection,
                  case .hostPort(let host, let port)? = connection.currentPath?.remoteEndpoint else { return }
            var address = "\(host)"
            if let percent = address.firstIndex(of: "%") { address = String(address[..<percent]) }
            let text = address.contains(":") ? "[\(address)]:\(port.rawValue)" : "\(address):\(port.rawValue)"
            self.deliver([text])
        }
        connection.start(queue: queue)
    }

    private func deliver(_ endpoints: [String]) {
        let continuation = state.withLock { state -> CheckedContinuation<[String], Never>? in
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume(returning: endpoints)
        finish()
    }

    func finish() {
        let (continuation, browser, connections) = state.withLock { state in
            state.done = true
            defer {
                state.continuation = nil
                state.browser = nil
                state.connections = []
            }
            return (state.continuation, state.browser, state.connections)
        }
        continuation?.resume(returning: [])
        browser?.cancel()
        for connection in connections { connection.cancel() }
    }
}
