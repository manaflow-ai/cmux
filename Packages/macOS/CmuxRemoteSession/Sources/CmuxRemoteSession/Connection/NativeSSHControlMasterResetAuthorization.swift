internal import Foundation

/// Holds the resolved authentication and process-ownership locks for one reset.
// SAFETY: `lock` serializes every read and mutation of the release closure.
final class NativeSSHControlMasterResetAuthorization: @unchecked Sendable {
    // lint:allow lock - release can arrive from task completion or deinit.
    private let lock = NSLock()
    private var releaseHandler: (@Sendable () -> Void)?

    init(releaseHandler: @escaping @Sendable () -> Void) {
        self.releaseHandler = releaseHandler
    }

    func release() {
        let handler = lock.withLock {
            defer { releaseHandler = nil }
            return releaseHandler
        }
        handler?()
    }

    deinit {
        release()
    }
}
