public import CmuxNextPages
public import Foundation

/// The app's bounded, cookieless fetch queue for passive Thread details icons.
/// Duplicate origins share a checked fetch; cancelling the last reader cancels its transport.
public actor AgentPaneSourceIcons {
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
                decode: @escaping @Sendable (Data) -> Data? = { $0 }) {
        self.maximumConcurrent = max(1, maximumConcurrent)
        self.maximumQueued = max(0, maximumQueued)
        self.fetch = fetch
        self.decode = decode
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
            // task-owner: this queue; the slot covers both network work and off-main image decoding.
            running[id] = Task.detached(priority: .utility) {
                let result = await fetch.fetch(url)
                let body: Data?
                switch result {
                case .success(let response): body = Task.isCancelled ? nil : decode(response.body)
                case .failure: body = nil
                }
                await self.finish(url, id: id, body: body)
            }
        }
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
