import AppKit
import Foundation

/// A bounded, deduplicating repository for inline-image thumbnail work.
actor TerminalInlineImageThumbnailCache {
    typealias MetadataKeyProvider = @Sendable (String) -> String?
    typealias Decode = @Sendable (String) async -> TerminalInlineImageThumbnail?

    private struct DecodeRequestToken: Equatable, Sendable {
        let id: UUID
        let cacheGeneration: UInt64
    }

    private let cache = NSCache<NSString, CGImage>()
    private var cachedKeyByPath: [String: String] = [:]
    private var cachedPathOrder: [String] = []
    private let maximumCachedPathKeys = 384
    private let maximumConcurrentDecodes: Int
    private let maximumPendingDecodes: Int
    private let metadataKeyProvider: MetadataKeyProvider
    private let decode: Decode
    private var waitersByKey: [String: [UUID: CheckedContinuation<TerminalInlineImageThumbnail?, Never>]] = [:]
    private var pathByKey: [String: String] = [:]
    private var pendingKeys: [String] = []
    private var pendingKeySet: Set<String> = []
    private var activeTasksByKey: [String: Task<Void, Never>] = [:]
    private var requestTokenByKey: [String: DecodeRequestToken] = [:]
    private var cacheGeneration: UInt64 = 0

    init(
        maximumConcurrentDecodes: Int = 2,
        maximumPendingDecodes: Int = 128,
        metadataKeyProvider: @escaping MetadataKeyProvider = {
            TerminalInlineImageThumbnailDecoder().metadataKey(for: $0)
        },
        decode: @escaping Decode = { path in
            await TerminalInlineImageThumbnailDecoder().decode(path: path)
        }
    ) {
        self.maximumConcurrentDecodes = max(1, maximumConcurrentDecodes)
        self.maximumPendingDecodes = max(1, maximumPendingDecodes)
        self.metadataKeyProvider = metadataKeyProvider
        self.decode = decode
        cache.countLimit = 128
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func thumbnail(for path: String) async -> TerminalInlineImageThumbnail? {
        guard !Task.isCancelled else { return nil }
        guard let key = metadataKeyProvider(path) else {
            return cachedThumbnailForMissingFile(path: path)
        }
        if let cached = cachedThumbnail(for: key) {
            rememberCachedKey(key, for: path)
            return cached
        }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                enqueue(
                    waiterID: waiterID,
                    continuation: continuation,
                    path: path,
                    key: key
                )
            }
        } onCancel: { [weak self] in
            Task {
                await self?.cancelWaiter(id: waiterID, key: key)
            }
        }
    }

    func removeAll() {
        cacheGeneration &+= 1
        cache.removeAllObjects()
        cachedKeyByPath.removeAll()
        cachedPathOrder.removeAll()
        activeTasksByKey.values.forEach { $0.cancel() }
        let continuations = waitersByKey.values.flatMap { $0.values }
        waitersByKey.removeAll()
        pathByKey.removeAll()
        requestTokenByKey.removeAll()
        pendingKeys.removeAll()
        pendingKeySet.removeAll()
        continuations.forEach { $0.resume(returning: nil) }
    }

    private func enqueue(
        waiterID: UUID,
        continuation: CheckedContinuation<TerminalInlineImageThumbnail?, Never>,
        path: String,
        key: String
    ) {
        if var waiters = waitersByKey[key] {
            waiters[waiterID] = continuation
            waitersByKey[key] = waiters
            return
        }
        let canStartImmediately = activeTasksByKey[key] == nil
            && activeTasksByKey.count < maximumConcurrentDecodes
        guard canStartImmediately || pendingKeys.count < maximumPendingDecodes else {
            continuation.resume(returning: nil)
            return
        }
        waitersByKey[key] = [waiterID: continuation]
        pathByKey[key] = path
        requestTokenByKey[key] = DecodeRequestToken(
            id: UUID(),
            cacheGeneration: cacheGeneration
        )
        if pendingKeySet.insert(key).inserted {
            pendingKeys.append(key)
        }
        startPendingDecodesIfPossible()
    }

    private func startPendingDecodesIfPossible() {
        while activeTasksByKey.count < maximumConcurrentDecodes,
              let nextIndex = pendingKeys.firstIndex(where: { activeTasksByKey[$0] == nil }) {
            let key = pendingKeys.remove(at: nextIndex)
            pendingKeySet.remove(key)
            guard let path = pathByKey[key],
                  waitersByKey[key] != nil,
                  let requestToken = requestTokenByKey[key] else {
                continue
            }
            let decode = decode
            activeTasksByKey[key] = Task { [weak self, decode, key, path] in
                let thumbnail = await decode(path)
                let result = Task.isCancelled ? nil : thumbnail
                await self?.decodeDidFinish(
                    result,
                    path: path,
                    key: key,
                    requestToken: requestToken
                )
            }
        }
    }

    private func decodeDidFinish(
        _ thumbnail: TerminalInlineImageThumbnail?,
        path: String,
        key: String,
        requestToken: DecodeRequestToken
    ) {
        activeTasksByKey.removeValue(forKey: key)
        guard requestTokenByKey[key] == requestToken else {
            startPendingDecodesIfPossible()
            return
        }
        let currentKey = metadataKeyProvider(path)
        let currentThumbnail = requestToken.cacheGeneration == cacheGeneration && currentKey == key ? thumbnail : nil
        if let currentThumbnail {
            cache.setObject(currentThumbnail.cgImage, forKey: key as NSString, cost: currentThumbnail.cost)
            rememberCachedKey(key, for: path)
        }
        let waiters = waitersByKey.removeValue(forKey: key)?.values ?? [:].values
        pathByKey.removeValue(forKey: key)
        requestTokenByKey.removeValue(forKey: key)
        for continuation in waiters {
            continuation.resume(returning: currentThumbnail)
        }
        startPendingDecodesIfPossible()
    }

    private func cancelWaiter(id: UUID, key: String) {
        guard var waiters = waitersByKey[key],
              let continuation = waiters.removeValue(forKey: id) else {
            return
        }
        continuation.resume(returning: nil)
        if waiters.isEmpty {
            removePendingKey(key)
            if let activeTask = activeTasksByKey[key] {
                waitersByKey.removeValue(forKey: key)
                pathByKey.removeValue(forKey: key)
                requestTokenByKey.removeValue(forKey: key)
                activeTask.cancel()
            } else {
                waitersByKey.removeValue(forKey: key)
                pathByKey.removeValue(forKey: key)
                requestTokenByKey.removeValue(forKey: key)
            }
            startPendingDecodesIfPossible()
        } else {
            waitersByKey[key] = waiters
        }
    }

    private func cachedThumbnailForMissingFile(path: String) -> TerminalInlineImageThumbnail? {
        guard let previousKey = cachedKeyByPath[path] else { return nil }
        return cachedThumbnail(for: previousKey)
    }

    private func cachedThumbnail(for key: String) -> TerminalInlineImageThumbnail? {
        guard let image = cache.object(forKey: key as NSString) else { return nil }
        let cost = max(1, image.width * image.height * 4)
        return TerminalInlineImageThumbnail(
            cgImage: image,
            pixelSize: CGSize(width: image.width, height: image.height),
            cost: cost
        )
    }

    private func rememberCachedKey(_ key: String, for path: String) {
        if cachedKeyByPath[path] == nil {
            cachedPathOrder.append(path)
        }
        cachedKeyByPath[path] = key
        guard cachedPathOrder.count > maximumCachedPathKeys else { return }
        let overflow = cachedPathOrder.count - maximumCachedPathKeys
        for expiredPath in cachedPathOrder.prefix(overflow) {
            cachedKeyByPath.removeValue(forKey: expiredPath)
        }
        cachedPathOrder.removeFirst(overflow)
    }

    private func removePendingKey(_ key: String) {
        guard pendingKeySet.remove(key) != nil,
              let index = pendingKeys.firstIndex(of: key) else {
            return
        }
        pendingKeys.remove(at: index)
    }
}
