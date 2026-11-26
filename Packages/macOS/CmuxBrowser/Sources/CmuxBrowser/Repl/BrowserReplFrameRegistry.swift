import Foundation

/// The frames of one tab, read once and reused.
///
/// Reading a tab's frame tree is expensive: WebKit asks every web process
/// that hosts one of its frames. A driver that reads the tree for every
/// frame call pays that per call, and a burst of calls (a snapshot of a page
/// with 300 iframes) queues hundreds of reads behind each other.
///
/// The registry answers lookups by id from its last read; frame ids are
/// stable for a frame's life, so a known id needs no read. A caller that
/// needs the tree as it is now (positions of child frames, the frame list)
/// asks for a fresh read: one that starts after the request. Requests that
/// arrive while a read is in flight share the next read, so a burst costs at
/// most two reads and at most one is ever in flight.
@MainActor
public final class BrowserReplFrameRegistry<Frame> {
    private let id: (Frame) -> String
    private let read: @MainActor () async -> [Frame]
    private var frames: [Frame]?
    private var byID: [String: Frame] = [:]
    private var reading = false
    /// Callers waiting for the read after the one in flight.
    private var nextWaiters: [CheckedContinuation<Void, Never>] = []
    /// Callers waiting for the read in flight.
    private var currentWaiters: [CheckedContinuation<Void, Never>] = []
    /// The result of the latest read, which resumed waiters return.
    private var latest: [Frame] = []

    /// - Parameters:
    ///   - id: A frame's stable id.
    ///   - read: Reads the whole frame tree, in document order.
    public init(id: @escaping (Frame) -> String, read: @escaping @MainActor () async -> [Frame]) {
        self.id = id
        self.read = read
    }

    /// Every frame: from the last read, or with `refresh` from a read that
    /// starts after this call.
    public func frames(refresh: Bool = false) async -> [Frame] {
        if !refresh, let frames { return frames }
        return await freshRead()
    }

    /// The frame with `id`. An id the last read does not have reads again
    /// once, since the page may have added the frame since.
    public func frame(_ id: String) async -> Frame? {
        if let frame = byID[id] { return frame }
        // A read in flight may already have it; else read the tree now.
        if reading {
            await withCheckedContinuation { currentWaiters.append($0) }
            if let frame = byID[id] { return frame }
        }
        _ = await freshRead()
        return byID[id]
    }

    /// Forgets the last read.
    public func invalidate() {
        frames = nil
        byID = [:]
    }

    private func freshRead() async -> [Frame] {
        if reading {
            await withCheckedContinuation { nextWaiters.append($0) }
            return latest
        }
        reading = true
        var result = await read()
        store(result)
        // Requests made during that read need one that started after them.
        while !nextWaiters.isEmpty {
            let waiters = nextWaiters
            nextWaiters = []
            result = await read()
            store(result)
            for waiter in waiters { waiter.resume() }
        }
        reading = false
        return result
    }

    private func store(_ result: [Frame]) {
        latest = result
        frames = result
        var index: [String: Frame] = [:]
        for frame in result { index[id(frame)] = frame }
        byID = index
        let waiters = currentWaiters
        currentWaiters = []
        for waiter in waiters { waiter.resume() }
    }
}
