import Foundation
@testable import CmuxUpdater

final class CapturingUpdateLog: UpdateLogging, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var messages: [String] = []

    func append(_ message: String) {
        lock.withLock {
            messages.append(message)
        }
    }

    func logPath() -> String { "/tmp/cmux-update-test.log" }
}
