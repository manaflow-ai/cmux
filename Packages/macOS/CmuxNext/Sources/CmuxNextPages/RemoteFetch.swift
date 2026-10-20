import CmuxNextCompat
public import Foundation

/// One GET to one checked address.
public nonisolated struct RemoteFetchRequest: Equatable, Sendable {
    public let address: RemoteAddress
    /// The URL's host: the TLS server name and the `Host` header.
    public let host: String
    public let port: Int
    /// The path and query.
    public let target: String
    public let headers: [String: String]
    /// Accept an identity-encoded body prefix at the byte cap (for HTML discovery only).
    public let allowsTruncation: Bool

    public init(address: RemoteAddress, host: String, port: Int, target: String, headers: [String: String], allowsTruncation: Bool = false) {
        self.address = address
        self.host = host
        self.port = port
        self.target = target
        self.headers = headers
        self.allowsTruncation = allowsTruncation
    }
}

public nonisolated struct RemoteFetchResponse: Equatable, Sendable {
    public let status: Int
    /// Lowercased names.
    public let headers: [String: String]
    public let body: Data
    /// The final checked URL after redirects; set by ``GuardedRemoteFetch``.
    public let finalURL: URL?

    public init(status: Int, headers: [String: String], body: Data, finalURL: URL? = nil) {
        self.status = status
        self.headers = headers
        self.body = body
        self.finalURL = finalURL
    }
}

/// Sends one request to its address and returns the answer, failing past `maximumBytes` of body
/// unless the request explicitly allows an identity-encoded prefix, which stops at that cap.
/// It never resolves a name: the address is the one the fetch checked.
public protocol RemoteFetchTransport: Sendable {
    func send(_ request: RemoteFetchRequest, maximumBytes: Int) async throws -> RemoteFetchResponse
}

/// Why a guarded fetch gave no body.
public nonisolated enum RemoteFetchFailure: Error, Equatable, Sendable {
    /// The URL, a name or an address is not allowed.
    case refused
    /// The network, TLS, the reply or the deadline failed.
    case failed
    /// The body is over the cap.
    case tooLarge
}

/// A host fetch for page content whose URL is untrusted (markdown remote images; agent pane reply
/// images and media). Every hop: https only, no URL credentials, no `localhost`, `.local` or
/// `.internal` name; the name is resolved ONCE and every address it resolves to must be public
/// (``RemoteAddress/isPublic``); the connection goes to exactly a checked address
/// (``RemoteFetchTransport`` never resolves again, so a DNS rebinding between the check and the
/// connect cannot move the target), with the URL's host as the TLS server name and `Host`
/// header. HTTP/1.1 with a browser's headers; chunked replies and gzip, deflate or br bodies are
/// decoded. At most ``maximumRedirects`` redirects, each checked the same way; any 2xx answer is
/// the body; at most ``maximumBytes`` of body on the wire and decoded; the whole fetch, redirects
/// included, within ``timeout``. ``allowsTruncation`` opts HTML discovery into an identity-encoded
/// prefix at the same byte cap; the transport closes as soon as that prefix arrives.
public nonisolated struct GuardedRemoteFetch: Sendable {
    public static let maximumRedirects = 3
    /// At most this many checked addresses of one host are tried when a connection fails before
    /// any byte is sent.
    static let maximumAddresses = 4

    /// A browser's `User-Agent`: image hosts and CDNs refuse or degrade unknown clients.
    public static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
    /// The `Accept` of a browser's image request.
    public static let imageAccept = "image/webp,image/avif,image/png,image/svg+xml,image/*;q=0.8,*/*;q=0.5"
    /// The `Accept` for bounded HTML icon discovery.
    public static let htmlAccept = "text/html,application/xhtml+xml;q=0.9,*/*;q=0.5"
    /// The `Accept` of a browser's video or audio request.
    public static let mediaAccept = "video/*,audio/*;q=0.9,*/*;q=0.5"
    /// A fixed `Accept-Language`, as browsers send one: the person's own languages would tell
    /// every host a reply or a document names which languages they read.
    static let acceptLanguage = "en-US,en;q=0.9"

    public var maximumBytes: Int
    public var timeout: Duration
    /// The `Accept` header.
    public var accept: String
    /// Return at most ``maximumBytes`` of identity-encoded HTML, stopping the connection at
    /// that cap. Defaults to false, preserving strict whole-body limits for images/media.
    /// Requests `Accept-Encoding: identity`; an encoded response is refused in this mode.
    public var allowsTruncation = false
    public var resolver: any RemoteAddressResolving
    public var transport: any RemoteFetchTransport
    public var clock: any Clock<Duration>

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

    /// The host without IPv6 brackets, lowercased.
    public static func host(of url: URL) -> String? {
        guard var host = url.host(percentEncoded: false)?.lowercased() else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return host
    }

    /// The body of a 2xx answer for `url`, following checked redirects.
    public func fetch(_ url: URL) async -> Result<RemoteFetchResponse, RemoteFetchFailure> {
        // A local copy lets the compiler open the existential clock (a stored property is not opened).
        let clock = clock
        return await fetch(url, clock: clock)
    }

    private func fetch<C: Clock>(_ url: URL, clock: C) async -> Result<RemoteFetchResponse, RemoteFetchFailure> where C.Duration == Duration {
        let race = DeadlineRace()
        let expires = clock.now.advanced(by: timeout)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.arm(continuation)
                // task-owner: the fetch; the race resumes the caller with whichever ends first
                let work = Task { race.finish(await follow(url)) }
                // task-owner: the deadline; it cancels the fetch when it fires first
                let deadline = Task {
                    do { try await clock.sleep(until: expires, tolerance: nil) } catch { return } // wakeup-allow: bounded remote fetch deadline
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
            guard allowsTruncation || response.body.count <= maximumBytes else { return .failure(.tooLarge) }
            return .success(RemoteFetchResponse(status: response.status, headers: response.headers,
                                               body: allowsTruncation ? Data(response.body.prefix(maximumBytes)) : response.body,
                                               finalURL: url))
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
            "Host": hostHeader, "Accept": accept, "Accept-Encoding": allowsTruncation ? "identity" : RemoteFetchContentDecoding.accepted,
            "Accept-Language": Self.acceptLanguage, "Connection": "close", "User-Agent": Self.userAgent,
        ], allowsTruncation: allowsTruncation)
    }
}

/// Resumes the caller once, with the fetch's result or the deadline's, and cancels the loser.
private nonisolated final class DeadlineRace: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Result<RemoteFetchResponse, RemoteFetchFailure>, Never>?
        var result: Result<RemoteFetchResponse, RemoteFetchFailure>?
        var tasks: [Task<Void, Never>] = []
    }

    // carve-out: a cancel handler and two tasks race to resume one continuation; the lock keeps
    // that exactly-once and synchronous (an actor hop could not run inside onCancel).
    private let state = Mutex(State())

    func arm(_ continuation: CheckedContinuation<Result<RemoteFetchResponse, RemoteFetchFailure>, Never>) {
        let early = state.withLock { state -> Result<RemoteFetchResponse, RemoteFetchFailure>? in
            if let result = state.result { return result }
            state.continuation = continuation
            return nil
        }
        if let early { continuation.resume(returning: early) }
    }

    func own(_ tasks: Task<Void, Never>...) {
        let done = state.withLock { state -> Bool in
            state.tasks += tasks
            return state.result != nil
        }
        if done { tasks.forEach { $0.cancel() } }
    }

    func finish(_ result: Result<RemoteFetchResponse, RemoteFetchFailure>) {
        let (continuation, tasks) = state.withLock { state -> (CheckedContinuation<Result<RemoteFetchResponse, RemoteFetchFailure>, Never>?, [Task<Void, Never>]) in
            guard state.result == nil else { return (nil, []) }
            state.result = result
            defer { state.continuation = nil }
            return (state.continuation, state.tasks)
        }
        tasks.forEach { $0.cancel() }
        continuation?.resume(returning: result)
    }
}
