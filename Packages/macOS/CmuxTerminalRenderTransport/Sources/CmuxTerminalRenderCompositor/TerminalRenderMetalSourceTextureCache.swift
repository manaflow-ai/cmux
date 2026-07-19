internal import CmuxTerminalRenderProtocol
internal import CmuxTerminalRenderTransport
internal import Foundation

/// Complete renderer and presentation lifetime for one imported Metal texture.
struct TerminalRenderMetalSourceTextureCacheKey: Equatable, Hashable, Sendable {
    let daemonInstanceID: UUID
    let workerProcessID: Int32
    let workerEffectiveUserID: UInt32
    let workerProcessInstanceToken: TerminalRenderProcessInstanceToken
    let rendererEpoch: UInt64
    let presentationID: UUID
    let presentationGeneration: UInt64
    let surfaceID: UInt32
    let width: UInt32
    let height: UInt32
    let pixelFormatRawValue: UInt32

    init(frame: TerminalRenderFrame) {
        daemonInstanceID = frame.metadata.daemonInstanceID
        workerProcessID = frame.workerIdentity.processID
        workerEffectiveUserID = frame.workerIdentity.effectiveUserID
        workerProcessInstanceToken = frame.workerIdentity.processInstanceToken
        rendererEpoch = frame.metadata.rendererEpoch
        presentationID = frame.metadata.presentationID
        presentationGeneration = frame.metadata.presentationGeneration
        surfaceID = frame.surface.identifier
        width = frame.metadata.width
        height = frame.metadata.height
        pixelFormatRawValue = frame.metadata.pixelFormat.rawValue
    }
}

/// Three-entry LRU matching the renderer presentation's minimum IOSurface pool.
///
/// This type is intentionally lock-free. Its production owner accesses it only
/// on `TerminalRenderMetalExecutor`, and its three-entry bound makes recency
/// updates constant-sized.
final class TerminalRenderMetalSourceTextureCache<Value> {
    let capacity: Int
    private var values: [TerminalRenderMetalSourceTextureCacheKey: Value] = [:]
    private var recency: [TerminalRenderMetalSourceTextureCacheKey] = []

    init(capacity: Int = 3) {
        precondition(capacity > 0)
        self.capacity = capacity
        values.reserveCapacity(capacity)
        recency.reserveCapacity(capacity)
    }

    var count: Int {
        values.count
    }

    func value(for key: TerminalRenderMetalSourceTextureCacheKey) -> Value? {
        guard let value = values[key] else { return nil }
        markMostRecent(key)
        return value
    }

    func insert(_ value: Value, for key: TerminalRenderMetalSourceTextureCacheKey) {
        values[key] = value
        markMostRecent(key)
        if values.count > capacity {
            let evicted = recency.removeFirst()
            values.removeValue(forKey: evicted)
        }
    }

    func removeAll() {
        values.removeAll(keepingCapacity: true)
        recency.removeAll(keepingCapacity: true)
    }

    private func markMostRecent(_ key: TerminalRenderMetalSourceTextureCacheKey) {
        if let existingIndex = recency.firstIndex(of: key) {
            recency.remove(at: existingIndex)
        }
        recency.append(key)
    }
}
