import Foundation
@testable import CmuxRemoteSession

final class RemoteProcessRunRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedResult: Result<RemoteCommandResult, any Error>?

    var result: Result<RemoteCommandResult, any Error>? {
        lock.withLock { storedResult }
    }

    func record(_ result: Result<RemoteCommandResult, any Error>) {
        lock.withLock {
            storedResult = result
        }
    }
}
