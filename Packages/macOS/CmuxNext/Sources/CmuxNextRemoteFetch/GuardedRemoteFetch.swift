public import Foundation

/// A host fetch for page content whose URL is untrusted (markdown remote images; agent pane reply
/// images and media). Every hop: https only, no URL credentials, no `localhost`, `.local` or
/// `.internal` name; the name is resolved ONCE and every address it resolves to must be public
/// (``RemoteAddress/isPublic``); the connection goes to exactly a checked address
/// (``RemoteFetchTransport`` never resolves again, so a DNS rebinding between the check and the
/// connect cannot move the target), with the URL's host as the TLS server name and `Host`
/// header. HTTP/1.1 with a browser's headers; chunked replies and gzip, deflate or br bodies are
/// decoded. At most ``maximumRedirects`` redirects, each checked the same way; any 2xx answer is
/// the body; at most ``maximumBytes`` of body on the wire and decoded; the whole fetch, redirects
/// included, within ``timeout``.
public nonisolated struct GuardedRemoteFetch: Sendable {
    public static let maximumRedirects = 3
    /// At most this many checked addresses of one host are tried when a connection fails before
    /// any byte is sent.
    static let maximumAddresses = 4

    /// A browser's `User-Agent`: image hosts and CDNs refuse or degrade unknown clients.
    public static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
    /// The `Accept` of a browser's image request.
    public static let imageAccept = "image/webp,image/avif,image/png,image/svg+xml,image/*;q=0.8,*/*;q=0.5"
    /// The `Accept` of a browser's video or audio request.
    public static let mediaAccept = "video/*,audio/*;q=0.9,*/*;q=0.5"
    /// A fixed `Accept-Language`, as browsers send one: the person's own languages would tell
    /// every host a reply or a document names which languages they read.
    static let acceptLanguage = "en-US,en;q=0.9"

    public var maximumBytes: Int
    public var timeout: Duration
    /// The `Accept` header.
    public var accept: String
    public var resolver: any RemoteAddressResolving
    public var transport: any RemoteFetchTransport
    public var clock: any Clock<Duration>
    /// When set, every hop (the first request and each redirect) must be to one of these hosts
    /// (``isListed(_:in:)``); a hop anywhere else fails the fetch before it connects.
    public var hosts: Set<String>?

    public init(maximumBytes: Int, timeout: Duration, accept: String, resolver: any RemoteAddressResolving = SystemRemoteResolver(),
                transport: any RemoteFetchTransport = PinnedTLSTransport(), clock: any Clock<Duration> = ContinuousClock()) {
        self.maximumBytes = maximumBytes
        self.timeout = timeout
        self.accept = accept
        self.resolver = resolver
        self.transport = transport
        self.clock = clock
    }

    /// Whether the URL itself may be fetched, before any network (its addresses are checked when
    /// it is fetched).
    public static func allows(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              let host = host(of: url), !host.isEmpty else { return false }
        let name = host.hasSuffix(".") ? String(host.dropLast()) : host
        if name == "localhost" || name.hasSuffix(".localhost") || name.hasSuffix(".local") || name.hasSuffix(".internal") {
            return false
        }
        // A literal is judged as written; a name (also a short or hex IPv4 spelling, which the
        // resolver turns into its address) is judged by what it resolves to.
        if let literal = RemoteAddress(literal: host) { return literal.isPublic }
        return true
    }

    /// Whether `url` may be fetched (``allows(_:)``) and its host is exactly one of `hosts`
    /// (lowercased names, never a suffix match), on the default https port.
    public static func isListed(_ url: URL, in hosts: Set<String>) -> Bool {
        guard allows(url), url.port == nil || url.port == 443, let host = host(of: url) else { return false }
        return hosts.contains(host)
    }

    /// The host without IPv6 brackets, lowercased.
    public static func host(of url: URL) -> String? {
        guard var host = url.host(percentEncoded: false)?.lowercased() else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return host
    }

    /// The body of a 2xx answer for `url`, following checked redirects.
    public func fetch(_ url: URL) async -> Result<RemoteFetchResponse, RemoteFetchFailure> {
        let race = DeadlineRace()
        let clock = clock
        let timeout = timeout
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.arm(continuation)
                // task-owner: the fetch; the race resumes the caller with whichever ends first
                let work = Task { race.finish(await follow(url)) }
                // task-owner: the deadline; it cancels the fetch when it fires first
                let deadline = Task {
                    do { try await clock.sleep(for: timeout) } catch { return } // wakeup-allow: bounded remote fetch deadline
                    race.finish(.failure(.failed))
                }
                race.own(work, deadline)
            }
        } onCancel: {
            race.finish(.failure(.failed))
        }
    }

    private func follow(_ start: URL) async -> Result<RemoteFetchResponse, RemoteFetchFailure> {
        var url = start
        // One request, then at most `maximumRedirects` more.
        for hop in 0...Self.maximumRedirects {
            guard !Task.isCancelled else { return .failure(.failed) }
            guard Self.allows(url), let host = Self.host(of: url) else { return .failure(.refused) }
            if let hosts, !Self.isListed(url, in: hosts) { return .failure(.refused) }
            let addresses: [RemoteAddress]
            if let literal = RemoteAddress(literal: host) {
                addresses = [literal]
            } else {
                guard let resolved = try? await resolver.resolve(host), !resolved.isEmpty else { return .failure(.refused) }
                addresses = resolved
            }
            // Every address the name has must be public, not only the one used.
            guard addresses.allSatisfy(\.isPublic) else { return .failure(.refused) }
            let response: RemoteFetchResponse
            switch await send(url, host: host, to: addresses.prefix(Self.maximumAddresses)) {
            case .success(let answer): response = answer
            case .failure(let failure): return .failure(failure)
            }
            if (300..<400).contains(response.status) {
                guard hop < Self.maximumRedirects, let location = response.headers["location"],
                      let next = URL(string: location, relativeTo: url)?.absoluteURL else { return .failure(.refused) }
                url = next
                continue
            }
            guard (200..<300).contains(response.status) else { return .failure(.failed) }
            guard response.body.count <= maximumBytes else { return .failure(.tooLarge) }
            return .success(response)
        }
        return .failure(.refused)
    }

    /// Sends the GET to the first checked address that connects.
    private func send(_ url: URL, host: String, to addresses: ArraySlice<RemoteAddress>) async -> Result<RemoteFetchResponse, RemoteFetchFailure> {
        for address in addresses {
            guard !Task.isCancelled else { return .failure(.failed) }
            do {
                return .success(try await transport.send(request(for: url, host: host, address: address), maximumBytes: maximumBytes))
            } catch is PinnedTLSTransport.ConnectFailure {
                continue
            } catch let refusal as RemoteFetchReplyReader.Refusal where refusal.overCap {
                return .failure(.tooLarge)
            } catch {
                return .failure(.failed)
            }
        }
        return .failure(.failed)
    }

    /// The GET for `url` to `address`: no cookies, credentials, referrer or auth headers.
    func request(for url: URL, host: String, address: RemoteAddress) -> RemoteFetchRequest {
        var target = url.path(percentEncoded: true)
        if target.isEmpty { target = "/" }
        if let query = url.query(percentEncoded: true) { target += "?" + query }
        let literalV6 = host.contains(":")
        let hostName = literalV6 ? "[\(host)]" : host
        let hostHeader = url.port.map { "\(hostName):\($0)" } ?? hostName
        return RemoteFetchRequest(address: address, host: host, port: url.port ?? 443, target: target, headers: [
            "Host": hostHeader, "Accept": accept, "Accept-Encoding": RemoteFetchContentDecoding.accepted,
            "Accept-Language": Self.acceptLanguage, "Connection": "close", "User-Agent": Self.userAgent,
        ])
    }
}
