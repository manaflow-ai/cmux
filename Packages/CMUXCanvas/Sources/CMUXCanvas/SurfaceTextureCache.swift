import CMUXLayout
import CoreGraphics
import Foundation

public enum CanvasSurfaceTextureKind: String, Codable, Sendable, Equatable {
    case live
    case snapshot
}

public struct CanvasSurfaceTextureKey: Hashable, Codable, Sendable, CustomStringConvertible {
    public var surfaceID: LayoutItemID
    public var kind: CanvasSurfaceTextureKind

    public init(surfaceID: LayoutItemID, kind: CanvasSurfaceTextureKind) {
        self.surfaceID = surfaceID
        self.kind = kind
    }

    public var description: String {
        "\(surfaceID.description):\(kind.rawValue)"
    }
}

public struct CanvasSurfaceTextureDescriptor: Codable, Sendable, Equatable {
    public var key: CanvasSurfaceTextureKey
    public var pixelSize: CGSize
    public var scale: CGFloat
    public var generation: UInt64

    public init(
        key: CanvasSurfaceTextureKey,
        pixelSize: CGSize,
        scale: CGFloat,
        generation: UInt64 = 0
    ) {
        self.key = key
        self.pixelSize = CGSize(
            width: max(1, pixelSize.width.isFinite ? pixelSize.width : 1),
            height: max(1, pixelSize.height.isFinite ? pixelSize.height : 1)
        )
        self.scale = max(0.0001, scale.isFinite ? scale : 1)
        self.generation = generation
    }
}

public final class SurfaceTextureCache: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptorsByKey: [CanvasSurfaceTextureKey: CanvasSurfaceTextureDescriptor] = [:]
    private var accessOrder: [CanvasSurfaceTextureKey] = []
    private var storedMaximumCount: Int

    public init(maximumCount: Int = 32) {
        self.storedMaximumCount = max(1, maximumCount)
    }

    public var maximumCount: Int {
        lock.withLock { storedMaximumCount }
    }

    public func setMaximumCount(_ maximumCount: Int) {
        lock.withLock {
            storedMaximumCount = max(1, maximumCount)
            evictIfNeeded()
        }
    }

    public func descriptor(for key: CanvasSurfaceTextureKey) -> CanvasSurfaceTextureDescriptor? {
        lock.withLock {
            guard let descriptor = descriptorsByKey[key] else { return nil }
            markAccessed(key)
            return descriptor
        }
    }

    public func store(_ descriptor: CanvasSurfaceTextureDescriptor) {
        lock.withLock {
            descriptorsByKey[descriptor.key] = descriptor
            markAccessed(descriptor.key)
            evictIfNeeded()
        }
    }

    public func remove(_ key: CanvasSurfaceTextureKey) {
        lock.withLock {
            descriptorsByKey.removeValue(forKey: key)
            accessOrder.removeAll { $0 == key }
        }
    }

    public func removeSurfaces(notIn visibleSurfaceIDs: Set<LayoutItemID>) {
        lock.withLock {
            let staleKeys = descriptorsByKey.keys.filter { !visibleSurfaceIDs.contains($0.surfaceID) }
            for key in staleKeys {
                descriptorsByKey.removeValue(forKey: key)
            }
            accessOrder.removeAll { !visibleSurfaceIDs.contains($0.surfaceID) }
        }
    }

    public func removeAll() {
        lock.withLock {
            descriptorsByKey.removeAll()
            accessOrder.removeAll()
        }
    }

    public var descriptors: [CanvasSurfaceTextureDescriptor] {
        lock.withLock {
            accessOrder.compactMap { descriptorsByKey[$0] }
        }
    }

    private func markAccessed(_ key: CanvasSurfaceTextureKey) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }

    private func evictIfNeeded() {
        while accessOrder.count > storedMaximumCount, let oldest = accessOrder.first {
            accessOrder.removeFirst()
            descriptorsByKey.removeValue(forKey: oldest)
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
