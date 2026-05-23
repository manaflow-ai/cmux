import Foundation

enum UpdateOperationTimeoutError {
    static let domain = "cmux.update.timeout"

    enum Code: Int {
        case checking = 1
        case downloading = 2
    }

    static func checking(after duration: TimeInterval) -> NSError {
        make(
            code: .checking,
            description: String(
                localized: "update.error.checkTimedOut.message",
                defaultValue: "cmux couldn't finish checking for updates in time. Try again in a moment."
            ),
            duration: duration
        )
    }

    static func downloading(after duration: TimeInterval) -> NSError {
        make(
            code: .downloading,
            description: String(
                localized: "update.error.downloadStalled.message",
                defaultValue: "The update download stopped making progress. Check your connection and try again."
            ),
            duration: duration
        )
    }

    private static func make(code: Code, description: String, duration: TimeInterval) -> NSError {
        NSError(
            domain: domain,
            code: code.rawValue,
            userInfo: [
                NSLocalizedDescriptionKey: description,
                "TimeoutDuration": duration,
            ]
        )
    }
}
