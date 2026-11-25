public import CoreGraphics

/// Evicted terminals' downscaled pictures (``TerminalLastFrames/picture(_:)``): least recently kept first out past
/// ``capacityBytes``. Each is rendered off the main thread as its terminal is evicted; a newer eviction or a
/// ``drop(_:)`` (the tab closed or shows again) while one renders discards it.
@MainActor
final class TerminalEvictedPictures {
    /// A kept picture's longest side, in pixels: the sidebar miniature's request at 2x, larger than a tab card's.
    nonisolated static let side: CGFloat = 640

    let capacityBytes: Int
    private var images: [String: CGImage] = [:]
    private var costs: [String: Int] = [:]
    private var order: [String] = []
    private var totalBytes = 0
    private var renders: [String: (id: UInt64, task: Task<Void, Never>)] = [:]
    private var nextID: UInt64 = 0

    init(capacityBytes: Int = 24 << 20) { self.capacityBytes = capacityBytes }

    func image(_ key: String) -> CGImage? { images[key] }

    /// Renders `key`'s picture with `render` and keeps it, unless dropped or replaced meanwhile.
    func keep(_ key: String, render: @escaping @MainActor () async -> CGImage?) {
        nextID &+= 1
        let id = nextID
        renders[key]?.task.cancel()
        let task = Task { [weak self] in  // task-owner: one bounded off-main render per eviction; drop cancels it
            let image = await render()
            guard let self, self.renders[key]?.id == id else { return }
            self.renders[key] = nil
            if let image { self.insert(image, for: key) }
        }
        renders[key] = (id, task)
    }

    func drop(_ key: String) {
        renders.removeValue(forKey: key)?.task.cancel()
        guard images.removeValue(forKey: key) != nil else { return }
        totalBytes -= costs.removeValue(forKey: key) ?? 0
        order.removeAll { $0 == key }
    }

    /// Resolves once `key`'s render, if any, ended (tests).
    func settled(_ key: String) async { await renders[key]?.task.value }

    private func insert(_ image: CGImage, for key: String) {
        let cost = max(image.bytesPerRow * image.height, image.width * image.height * 4)
        guard cost <= capacityBytes else { return }
        if images[key] != nil { drop(key) }
        images[key] = image
        costs[key] = cost
        order.append(key)
        totalBytes += cost
        while totalBytes > capacityBytes, let oldest = order.first { drop(oldest) }
    }
}
