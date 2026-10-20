import Foundation

actor CameraConfigurationCompileGate {
    private let libraryURL: URL
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(libraryURL: URL) {
        self.libraryURL = libraryURL
    }

    func compile() async -> URL {
        started = true
        let currentWaiters = waiters
        waiters.removeAll()
        currentWaiters.forEach { $0.resume() }
        await withCheckedContinuation { releaseContinuation = $0 }
        return libraryURL
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
