public import CmuxNextPages
public import Foundation

/// The pane module's bounded, cookieless fetch queue for passive Thread details icons.
/// Duplicate origins share a checked fetch; cancelling the last reader cancels its transport.
public actor AgentPaneSourceIcons {
    // Share one admission budget across panes, including readers of the same origin.
    static let shared = AgentPaneSourceIcons()

    private struct Entry {
        let id = UUID()
        var readers: [UUID: AsyncStream<AgentPaneSourceIconResult>.Continuation] = [:]
    }

    private let maximumConcurrent: Int
    private let maximumQueued: Int
    private let fetch: GuardedRemoteFetch
    private let decode: @Sendable (Data) -> Data?
    private let elapsed: @Sendable () -> Duration
    private var cache: AgentPaneSourceIconCache
    private var entries: [URL: Entry] = [:]
    private var queue: [URL] = []
    private var running: [UUID: Task<Void, Never>] = [:]

    public init(maximumConcurrent: Int = 4, maximumQueued: Int = 128, maximumCached: Int = 256,
                fetch: GuardedRemoteFetch = GuardedRemoteFetch(maximumBytes: 1 << 20, timeout: .seconds(10),
                                                              accept: GuardedRemoteFetch.imageAccept),
                decode: (@Sendable (Data) -> Data?)? = nil) {
        self.maximumConcurrent = max(1, maximumConcurrent)
        self.maximumQueued = max(0, maximumQueued)
        self.fetch = fetch
        // A local copy lets the compiler open the existential clock (a stored property is not opened).
        let clock = fetch.clock
        self.elapsed = Self.timeSource(clock)
        self.cache = AgentPaneSourceIconCache(capacity: maximumCached)
        self.decode = decode ?? { AgentPaneSourceIconPNG().decode($0) }
    }

    /// The bounded, decoded data, preserving the original optional-data interface.
    public func data(at url: URL) async -> Data? { await result(at: url).png }

    /// A completed icon or genuine miss, distinguished from overload and cancellation.
    public func result(at url: URL) async -> AgentPaneSourceIconResult {
        guard !Task.isCancelled else { return .temporary }
        let id = UUID()
        let reader = requestResult(at: url, id: id)
        return await withTaskCancellationHandler {
            let result = await reader.value
            return Task.isCancelled ? .temporary : result
        } onCancel: {
            // task-owner: one cancellation transition at the queue's owning actor.
            Task { await self.cancel(at: url, id: id) }
        }
    }

    func request(at url: URL, id: UUID) -> Task<Data?, Never> {
        let reader = requestResult(at: url, id: id)
        return Task { await reader.value.png }
    }

    func requestResult(at url: URL, id: UUID) -> Task<AgentPaneSourceIconResult, Never> {
        guard let url = Self.origin(url) else { return Task { .unavailable } }
        if let result = cache.result(at: url, now: elapsed()) { return Task { result } }
        if entries[url] == nil, running.count >= maximumConcurrent, queue.count >= maximumQueued { return Task { .temporary } }
        let (stream, continuation) = AsyncStream<AgentPaneSourceIconResult>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let isNew = entries[url] == nil
        var entry = entries[url] ?? Entry()
        entry.readers[id] = continuation
        entries[url] = entry
        if isNew { queue.append(url) }
        startAvailable()
        // task-owner: the reader; completion or cancellation finishes its stream.
        return Task {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next() ?? .temporary
        }
    }

    private static func origin(_ url: URL) -> URL? {
        guard GuardedRemoteFetch.allows(url), var origin = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        origin.scheme = "https"
        origin.host = origin.host?.lowercased()
        if origin.port == 443 { origin.port = nil }
        origin.path = "/favicon.ico"
        origin.query = nil
        origin.fragment = nil
        return origin.url
    }

    private static func timeSource<C: Clock>(_ clock: C) -> @Sendable () -> Duration where C.Duration == Duration {
        let start = clock.now
        return { start.duration(to: clock.now) }
    }

    func cancel(at url: URL, id: UUID) {
        guard let url = Self.origin(url), var entry = entries[url], let reader = entry.readers.removeValue(forKey: id) else { return }
        reader.yield(.temporary)
        reader.finish()
        if entry.readers.isEmpty {
            entries[url] = nil
            queue.removeAll { $0 == url }
            // Keep the slot occupied until the cancelled fetch has actually returned.
            running[entry.id]?.cancel()
        } else {
            entries[url] = entry
        }
    }

    private func startAvailable() {
        while running.count < maximumConcurrent, !queue.isEmpty {
            let url = queue.removeFirst()
            guard let entry = entries[url] else { continue }
            let fetch = fetch
            let decode = decode
            let id = entry.id
            // task-owner: this queue; one slot covers the entire fallback chain and off-main decoding.
            running[id] = Task.detached(priority: .utility) {
                let body = await AgentPaneSourceIconChain(fetch: fetch, decode: decode).load(url)
                await self.finish(url, id: id, body: body)
            }
        }
    }

    private func finish(_ url: URL, id: UUID, body: AgentPaneSourceIconResult) {
        running[id] = nil
        if let entry = entries[url], entry.id == id {
            entries[url] = nil
            cache.insert(body, at: url, now: elapsed())
            for reader in entry.readers.values {
                reader.yield(body)
                reader.finish()
            }
        }
        startAvailable()
    }
}
