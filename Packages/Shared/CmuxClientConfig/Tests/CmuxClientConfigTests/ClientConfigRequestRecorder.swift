import Foundation

final class ClientConfigRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [URLRequest] = []

    var requests: [URLRequest] {
        lock.withLock { storedRequests }
    }

    func record(_ request: URLRequest) {
        lock.withLock {
            storedRequests.append(request)
        }
    }

    func reset() {
        lock.withLock {
            storedRequests = []
        }
    }
}
