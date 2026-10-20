public import CmuxNextPages
public import Foundation

/// The pane module's bounded, cookieless fetch queue for passive Thread details icons.
/// Duplicate origins share a checked fetch; cancelling the last reader cancels its transport.
public actor AgentPaneSourceIcons {
    // Share one admission budget across panes, including readers of the same origin.
    static let shared = AgentPaneSourceIcons()

    private struct Entry {
        let id = UUID()
        var readers: [UUID: AsyncStream<Data?>.Continuation] = [:]
    }

    private let maximumConcurrent: Int
    private let maximumQueued: Int
    private let fetch: GuardedRemoteFetch
    private let decode: @Sendable (Data) -> Data?
    private var entries: [URL: Entry] = [:]
    private var queue: [URL] = []
    private var running: [UUID: Task<Void, Never>] = [:]

    public init(maximumConcurrent: Int = 4, maximumQueued: Int = 128,
                fetch: GuardedRemoteFetch = GuardedRemoteFetch(maximumBytes: 1 << 20, timeout: .seconds(10),
                                                              accept: GuardedRemoteFetch.imageAccept),
                decode: (@Sendable (Data) -> Data?)? = nil) {
        self.maximumConcurrent = max(1, maximumConcurrent)
        self.maximumQueued = max(0, maximumQueued)
        self.fetch = fetch
        self.decode = decode ?? { AgentPaneSourceIconPNG().decode($0) }
    }

    /// The bounded, decoded data at a public HTTPS origin, or nil on refusal, overload or cancellation.
    public func data(at url: URL) async -> Data? {
        guard !Task.isCancelled else { return nil }
        let id = UUID()
        let reader = request(at: url, id: id)
        return await withTaskCancellationHandler {
            await reader.value
        } onCancel: {
            // task-owner: one cancellation transition at the queue's owning actor.
            Task { await self.cancel(at: url, id: id) }
        }
    }

    func request(at url: URL, id: UUID) -> Task<Data?, Never> {
        guard GuardedRemoteFetch.allows(url) else { return Task { nil } }
        if entries[url] == nil, running.count >= maximumConcurrent, queue.count >= maximumQueued { return Task { nil } }
        let (stream, continuation) = AsyncStream<Data?>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let isNew = entries[url] == nil
        var entry = entries[url] ?? Entry()
        entry.readers[id] = continuation
        entries[url] = entry
        if isNew { queue.append(url) }
        startAvailable()
        // task-owner: the reader; completion or cancellation finishes its stream.
        return Task {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next() ?? nil
        }
    }

    func cancel(at url: URL, id: UUID) {
        guard var entry = entries[url], let reader = entry.readers.removeValue(forKey: id) else { return }
        reader.yield(nil)
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
                let body = await Self.load(url, fetch: fetch, decode: decode)
                await self.finish(url, id: id, body: body)
            }
        }
    }

    /// Runs under the queue's one transport owner, so each hop inherits its cancellation.
    private static func load(_ url: URL, fetch: GuardedRemoteFetch, decode: @Sendable (Data) -> Data?) async -> Data? {
        if case .success(let response) = await fetch.fetch(url), !Task.isCancelled,
           let png = decode(response.body) { return Task.isCancelled ? nil : png }
        guard !Task.isCancelled, var home = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        home.path = "/"
        home.query = nil
        home.fragment = nil
        guard let pageURL = home.url else { return nil }
        var htmlFetch = fetch
        htmlFetch.maximumBytes = 256 * 1024
        htmlFetch.accept = GuardedRemoteFetch.htmlAccept
        htmlFetch.allowsTruncation = true
        guard case .success(let page) = await htmlFetch.fetch(pageURL), !Task.isCancelled else { return nil }
        let candidates = AgentPaneSourceIconHTML().candidates(in: page.body, pageURL: page.finalURL ?? pageURL)
        for candidate in candidates.prefix(2) {
            guard !Task.isCancelled else { return nil }
            if case .success(let response) = await fetch.fetch(candidate), !Task.isCancelled,
               let png = decode(response.body) { return Task.isCancelled ? nil : png }
        }
        return nil
    }

    private func finish(_ url: URL, id: UUID, body: Data?) {
        running[id] = nil
        if let entry = entries[url], entry.id == id {
            entries[url] = nil
            for reader in entry.readers.values {
                reader.yield(body)
                reader.finish()
            }
        }
        startAvailable()
    }
}
