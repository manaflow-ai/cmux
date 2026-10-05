public import Foundation

/// Gets a remote suggest response. The App uses `URLSessionSuggestFetcher`;
/// tests inject a fake. A fetch must end with `CancellationError` (or any
/// error) soon after its task is cancelled.
public nonisolated protocol OmniboxSuggestFetching: Sendable {
    /// `ephemeral`: a private (incognito) profile asks; nothing may be
    /// cached, stored or logged.
    func fetch(_ url: URL, ephemeral: Bool) async throws -> Data
}

/// Suggest requests over URLSession: the shared session for normal profiles
/// (search engine cookies, such as a Kagi login, apply), an ephemeral one
/// for private profiles. Neither logs the request.
public nonisolated struct URLSessionSuggestFetcher: OmniboxSuggestFetching {
    private static let privateSession = URLSession(configuration: .ephemeral)

    public init() {}

    public func fetch(_ url: URL, ephemeral: Bool) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/json, application/x-suggestions+json", forHTTPHeaderField: "Accept")
        request.cachePolicy = ephemeral ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy
        let session = ephemeral ? Self.privateSession : URLSession.shared
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

/// Phase B settings of one suggestion engine (`browser.omnibar.remoteSuggestions`
/// and the Debug Settings tunables).
public nonisolated struct OmniboxRemoteConfiguration: Sendable {
    /// Remote suggestions are on. Off, or with no fetcher, phase B never runs.
    public var enabled = true
    /// Nil in an engine nobody wired to the network (tests, previews).
    public var fetcher: (any OmniboxSuggestFetching)?
    /// The engine serves a private profile: requests are ephemeral.
    public var isPrivate = false
    /// Quiet time after a keystroke before a request starts.
    public var debounce: Duration = .milliseconds(40)
    /// A request still running after this is cancelled.
    public var timeout: Duration = .milliseconds(800)
    public var clock: any Clock<Duration> = ContinuousClock()
    /// At most this many remote rows.
    public var limit = 4

    public init(enabled: Bool = true, fetcher: (any OmniboxSuggestFetching)? = nil, isPrivate: Bool = false) {
        self.enabled = enabled
        self.fetcher = fetcher
        self.isPrivate = isPrivate
    }
}

extension OmniboxSuggestionEngine {
    /// Phase B for `text`: after `remote.debounce` without cancellation, one
    /// request to the engine's suggest endpoint, cancelled after
    /// `remote.timeout` or with the query; nil when anything fails.
    static func remoteRows(_ text: String, engine: BrowserSearchEngine, remote: OmniboxRemoteConfiguration) async -> [BrowserSuggestion]? {
        guard let fetcher = remote.fetcher, let url = engine.suggestURL(for: text) else { return nil }
        let clock = remote.clock, timeout = remote.timeout, ephemeral = remote.isPrivate
        do {
            // wakeup-allow: one-shot debounce on the injected clock; a newer keystroke cancels it.
            try await clock.sleep(for: remote.debounce)
        } catch {
            return nil
        }
        guard !Task.isCancelled else { return nil }
        let fetch = Task { try await fetcher.fetch(url, ephemeral: ephemeral) }
        let deadline = Task {
            // wakeup-allow: one-shot request deadline on the injected clock, cancelled when the fetch ends.
            try await clock.sleep(for: timeout)
            fetch.cancel()
        }
        defer { deadline.cancel() }
        let data = await withTaskCancellationHandler {
            try? await fetch.value
        } onCancel: {
            fetch.cancel()
        }
        guard let data, !Task.isCancelled else { return nil }
        return OmniboxRemoteSuggestions.rows(OmniboxRemoteSuggestions.parse(data), query: text, engine: engine, limit: remote.limit)
    }
}
