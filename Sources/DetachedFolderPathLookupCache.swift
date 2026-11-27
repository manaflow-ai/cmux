@MainActor
final class DetachedFolderPathLookupCache<Value> {
    private let capacity: Int
    private let maxPendingPaths: Int
    private let maxCallbacksPerPath: Int
    private var valuesByPath: [String: Value] = [:]
    private var lruPaths: [String] = []
    private var pendingCallbacksByPath: [String: [(Value) -> Void]] = [:]

    init(capacity: Int = 256, maxPendingPaths: Int = 256, maxCallbacksPerPath: Int = 64) {
        self.capacity = max(1, capacity)
        self.maxPendingPaths = max(1, maxPendingPaths)
        self.maxCallbacksPerPath = max(1, maxCallbacksPerPath)
    }

    var pendingPathCount: Int { pendingCallbacksByPath.count }

    func pendingCallbackCount(forPath path: String) -> Int {
        pendingCallbacksByPath[path]?.count ?? 0
    }

    func value(forPath path: String) -> Value? {
        guard let value = valuesByPath[path] else { return nil }
        touch(path)
        return value
    }

    /// Returns true only for the first queued callback for a path, which is the
    /// caller's signal to start exactly one off-main lookup task.
    func enqueueCallback(forPath path: String, callback: @escaping (Value) -> Void) -> Bool {
        if var callbacks = pendingCallbacksByPath[path] {
            if callbacks.count < maxCallbacksPerPath {
                callbacks.append(callback)
                pendingCallbacksByPath[path] = callbacks
            }
            return false
        }
        guard pendingCallbacksByPath.count < maxPendingPaths else { return false }
        pendingCallbacksByPath[path] = [callback]
        return true
    }

    func resolve(path: String, value: Value) {
        valuesByPath[path] = value
        touch(path)
        let callbacks = pendingCallbacksByPath.removeValue(forKey: path) ?? []
        for callback in callbacks {
            callback(value)
        }
    }

    private func touch(_ path: String) {
        if let existingIndex = lruPaths.firstIndex(of: path) {
            lruPaths.remove(at: existingIndex)
        }
        lruPaths.append(path)
        while lruPaths.count > capacity, let evicted = lruPaths.first {
            lruPaths.removeFirst()
            valuesByPath[evicted] = nil
        }
    }
}
