import CmuxNextPages
import Foundation

/// One total network deadline covers ICO, HTML discovery and two previously untried candidates.
nonisolated struct AgentPaneSourceIconChain: Sendable {
    let fetch: GuardedRemoteFetch
    let decode: @Sendable (Data) -> Data?

    func load(_ url: URL) async -> AgentPaneSourceIconResult {
        // A local copy lets the compiler open the existential clock (a stored property is not opened).
        let clock = fetch.clock
        return await load(url, clock: clock)
    }

    private func load<C: Clock>(_ url: URL, clock: C) async -> AgentPaneSourceIconResult where C.Duration == Duration {
        let deadline = clock.now.advanced(by: .seconds(12))
        var fetch = fetch
        let transport = AgentPaneSourceIconTransport(fetch.transport)
        fetch.transport = transport
        let resolver = AgentPaneSourceIconResolver(fetch.resolver)
        fetch.resolver = resolver
        var attempted: Set<URL> = [url]
        func expired() -> Bool { Task.isCancelled || clock.now >= deadline }
        func bounded(_ request: GuardedRemoteFetch) -> GuardedRemoteFetch {
            var request = request
            request.timeout = min(request.timeout, clock.now.duration(to: deadline))
            return request
        }
        func checked(_ request: GuardedRemoteFetch, _ target: URL) async -> (Result<RemoteFetchResponse, RemoteFetchFailure>, Bool) {
            let checkpoint = await transport.checkpoint()
            let lookupFailures = await resolver.failures
            let result = await bounded(request).fetch(target)
            // Failed DNS lookups are transient; resolved but blocked addresses are definitive.
            if case .failure(.refused) = result { return (result, await resolver.failures > lookupFailures) }
            return (result, await transport.needsRetry(since: checkpoint))
        }
        let (ico, icoTemporary) = await checked(fetch, url)
        var temporary = icoTemporary
        if case .success(let response) = ico, !expired() {
            if let final = response.finalURL { attempted.insert(final) }
            if let png = decode(response.body) { return expired() ? .temporary : .icon(png) }
        }
        guard !expired(), var home = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return .temporary }
        home.path = "/"
        home.query = nil
        home.fragment = nil
        guard let pageURL = home.url else { return .unavailable }
        attempted.insert(pageURL)
        var htmlFetch = fetch
        htmlFetch.maximumBytes = 256 * 1024
        htmlFetch.accept = GuardedRemoteFetch.htmlAccept
        htmlFetch.allowsTruncation = true
        let homeResult: Result<RemoteFetchResponse, RemoteFetchFailure>
        let homeTemporary: Bool
        if case .success(let response) = ico, response.finalURL == pageURL {
            // The ICO redirect already fetched this bounded body; discovery scans at most 256 KiB.
            homeResult = .success(response)
            homeTemporary = false
        } else {
            (homeResult, homeTemporary) = await checked(htmlFetch, pageURL)
        }
        temporary = temporary || homeTemporary
        guard !expired() else { return .temporary }
        guard case .success(let page) = homeResult else { return temporary ? .temporary : .unavailable }
        if let final = page.finalURL { attempted.insert(final) }
        let candidates = AgentPaneSourceIconHTML().candidates(in: page.body, pageURL: page.finalURL ?? pageURL)
        for candidate in candidates.filter({ !attempted.contains($0) }).prefix(2) {
            guard !expired() else { return .temporary }
            attempted.insert(candidate)
            let (result, candidateTemporary) = await checked(fetch, candidate)
            temporary = temporary || candidateTemporary
            switch result {
            case .success(let response):
                if let final = response.finalURL { attempted.insert(final) }
                guard !expired() else { return .temporary }
                if let png = decode(response.body) { return expired() ? .temporary : .icon(png) }
            case .failure: break
            }
        }
        return expired() || temporary ? .temporary : .unavailable
    }
}
