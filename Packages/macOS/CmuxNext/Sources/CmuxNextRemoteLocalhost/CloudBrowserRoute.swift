import CmuxNextWakeups
public import Foundation

/// One Cloud machine's browser route that follows the machine's link (#25595).
///
/// A `cloud.browser.open` route belongs to one `cmux-cloud` process and one link generation: it
/// closes when the link drops or is replaced, and it is gone after the app quits. A tab that kept
/// the first route's opener failed every request from then on, and a tab restored after a relaunch
/// had no route at all. This opener asks for the machine's route again (``Fetch``) when it has none
/// or when the one it has is gone (``LoopbackTunnelFailure/unavailable(_:)``), then tries once more.
/// Concurrent requests share one fetch; a fetch that fails leaves the error page to the request.
/// Fetches are spaced by a capped ``Backoff`` until a request goes through, so a page that keeps
/// asking (a dev server's reload client) while the machine is down does not ask `cmux-cloud` each time.
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
    private let now: @Sendable () -> ContinuousClock.Instant
    private var spacing = Backoff(initial: .seconds(1), maximum: .seconds(30))
    /// No fetch before this instant (set by each fetch, cleared by a request that went through).
    private var notBefore: ContinuousClock.Instant?

    /// - Parameters:
    ///   - first: The route already answered (a tab opened now), or nil (a tab restored after a
    ///     relaunch: the first request fetches it).
    ///   - fetch: Asks for the route again.
    public init(first: Answer?, fetch: @escaping Fetch) {
        self.init(first: first, fetch: fetch, now: { .now }) { CloudProxyLoopbackOpener(proxyPort: $0.proxyPort, credential: $0.credential) }
    }

    /// Test seam: `now` reads the clock, `makeOpener` builds the opener of an answer.
    init(first: Answer?, fetch: @escaping Fetch, now: @escaping @Sendable () -> ContinuousClock.Instant,
         makeOpener: @escaping @Sendable (Answer) -> any LoopbackTunnelOpening) {
        self.fetch = fetch
        self.now = now
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
            return try await wentThrough(route.opener.openTunnel(host: host, port: port))
        } catch {
            // Only a route that is gone is asked for again: a port that refused stays refused.
            guard case .unavailable = error,
                  let fresh = await refreshed(after: route.number, host: host, port: port), fresh.number != route.number
            else { throw error }
            return try await wentThrough(fresh.opener.openTunnel(host: host, port: port))
        }
    }

    /// The machine connected again: the next request that needs a route fetches it at once.
    public func machineConnected() {
        spacing.reset()
        notBefore = nil
    }

    /// A request went through: the next fetch, when one is needed, goes at once.
    private func wentThrough(_ tunnel: any LoopbackTunnel) -> any LoopbackTunnel {
        spacing.reset()
        notBefore = nil
        return tunnel
    }

    /// The route after `stale` (nil: none yet): a newer one when another request already fetched
    /// it, else the answer of one shared fetch; nil when that fetch failed.
    private func refreshed(after stale: Int?, host: String, port: UInt16) async -> (opener: any LoopbackTunnelOpening, number: Int)? {
        if let current, current.number != stale { return current }
        if let fetching { return await fetching.value }
        if let notBefore, now() < notBefore { return nil }
        notBefore = now().advanced(by: spacing.next())
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
