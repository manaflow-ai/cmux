import Foundation

actor CameraReinjectionCompileGate {
    private let libraryURL: URL
    private var invocationCount = 0
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var wasCancelled = false

    init(libraryURL: URL) {
        self.libraryURL = libraryURL
    }

    func compiledLibrary() async -> URL {
        invocationCount += 1
        guard invocationCount > 1 else { return libraryURL }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
                let waiters = suspensionWaiters
                suspensionWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        } onCancel: {
            Task { await self.recordCancellation() }
        }
        return libraryURL
    }

    func waitUntilSuspended() async {
        if releaseContinuation != nil { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func waitUntilCancelled() async {
        if wasCancelled { return }
        await withCheckedContinuation { continuation in
            cancellationWaiters.append(continuation)
        }
    }

    private func recordCancellation() {
        wasCancelled = true
        releaseContinuation?.resume()
        releaseContinuation = nil
        let waiters = cancellationWaiters
        cancellationWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
