import Foundation

/// Injects failures inside a single transaction; it never crosses a task boundary.
final class HelperCopyFailureFileManager: FileManager {
    enum Failure: Equatable, Sendable {
        case copiedThenThrows
        case copiedThenCancelled
        case cleanupDenied
    }

    let failure: Failure

    init(_ failure: Failure) {
        self.failure = failure
        super.init()
    }

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        try super.copyItem(at: srcURL, to: dstURL)
        switch failure {
        case .copiedThenCancelled:
            withUnsafeCurrentTask { $0?.cancel() }
        case .copiedThenThrows, .cleanupDenied:
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    override func removeItem(at URL: URL) throws {
        if failure == .cleanupDenied { throw CocoaError(.fileWriteNoPermission) }
        try super.removeItem(at: URL)
    }
}
