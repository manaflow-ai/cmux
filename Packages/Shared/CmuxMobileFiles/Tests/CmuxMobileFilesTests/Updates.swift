import CmuxMobileFiles

/// Collects a run's updates until the stream ends, optionally acting on one.
struct Updates {
    static func collect(_ stream: AsyncStream<MobileTransferUpdate>,
                        onEach: @escaping @Sendable (MobileTransferUpdate) async -> Void = { _ in }) async throws
        -> [MobileTransferUpdate] {
        try await within {
            var all: [MobileTransferUpdate] = []
            for await update in stream {
                all.append(update)
                await onEach(update)
            }
            return all
        }
    }
}

actor Once {
    private var fired = false
    /// True the first time only.
    func fire() -> Bool {
        defer { fired = true }
        return !fired
    }
}
