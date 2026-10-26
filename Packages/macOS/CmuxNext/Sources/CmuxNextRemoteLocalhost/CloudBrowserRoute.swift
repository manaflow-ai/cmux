public import Foundation

/// One Cloud machine's browser route that follows the machine's link (#25595).
///
/// A `cloud.browser.open` route belongs to one `cmux-cloud` process and one link generation: it
/// closes when the link drops or is replaced, and it is gone after the app quits. A tab that kept
/// the first route's opener failed every request from then on, and a tab restored after a relaunch
/// had no route at all. This opener asks for the machine's route again (``Fetch``) when it has none
/// or when the one it has is gone (``LoopbackTunnelFailure/unavailable(_:)``), then tries once more.
/// Concurrent requests share one fetch; a fetch that fails leaves the error page to the request.
public actor CloudBrowserRoute: LoopbackTunnelOpening {
    /// A `cloud.browser.open` answer: the local `cmux-cloud` proxy and its credential.
    public struct Answer: Sendable, Equatable {
        public var proxyPort: UInt16
        public var credential: ProxyCredential

        public init(proxyPort: UInt16, credential: ProxyCredential) {
            self.proxyPort = proxyPort
            self.credential = credential
        }
    }

    /// Asks `cmux-cloud` for the machine's route, for a request to `host:port` on the machine.
    public typealias Fetch = @Sendable (_ host: String, _ port: UInt16) async throws -> Answer

    private let fetch: Fetch
    private let makeOpener: @Sendable (Answer) -> any LoopbackTunnelOpening
    /// The route in use and its number (bumped by each fetch that landed).
    private var current: (opener: any LoopbackTunnelOpening, number: Int)?
    private var number = 0
    private var fetching: Task<(opener: any LoopbackTunnelOpening, number: Int)?, Never>?

    /// - Parameters:
    ///   - first: The route already answered (a tab opened now), or nil (a tab restored after a
    ///     relaunch: the first request fetches it).
    ///   - fetch: Asks for the route again.
    public init(first: Answer?, fetch: @escaping Fetch) {
        self.init(first: first, fetch: fetch) { CloudProxyLoopbackOpener(proxyPort: $0.proxyPort, credential: $0.credential) }
    }

    /// Test seam: `makeOpener` builds the opener of an answer.
    init(first: Answer?, fetch: @escaping Fetch, makeOpener: @escaping @Sendable (Answer) -> any LoopbackTunnelOpening) {
        self.fetch = fetch
        self.makeOpener = makeOpener
        if let first {
            number = 1
            current = (makeOpener(first), 1)
        }
    }

    public func openTunnel(host: String, port: UInt16) async throws(LoopbackTunnelFailure) -> any LoopbackTunnel {
        let route: (opener: any LoopbackTunnelOpening, number: Int)
        if let current {
            route = current
        } else if let fetched = await refreshed(after: nil, host: host, port: port) {
            route = fetched
        } else {
            throw .unavailable("Cloud browser route unavailable")
        }
        do throws(LoopbackTunnelFailure) {
            return try await route.opener.openTunnel(host: host, port: port)
        } catch {
            // Only a route that is gone is asked for again: a port that refused stays refused.
            guard case .unavailable = error,
                  let fresh = await refreshed(after: route.number, host: host, port: port), fresh.number != route.number
            else { throw error }
            return try await fresh.opener.openTunnel(host: host, port: port)
        }
    }

    /// The route after `stale` (nil: none yet): a newer one when another request already fetched
    /// it, else the answer of one shared fetch; nil when that fetch failed.
    private func refreshed(after stale: Int?, host: String, port: UInt16) async -> (opener: any LoopbackTunnelOpening, number: Int)? {
        if let current, current.number != stale { return current }
        if let fetching { return await fetching.value }
        let task = Task { await self.fetchRoute(host: host, port: port) }
        fetching = task
        return await task.value
    }

    private func fetchRoute(host: String, port: UInt16) async -> (opener: any LoopbackTunnelOpening, number: Int)? {
        defer { fetching = nil }
        guard let answer = try? await fetch(host, port) else { return nil }
        number += 1
        current = (makeOpener(answer), number)
        return current
    }
}
