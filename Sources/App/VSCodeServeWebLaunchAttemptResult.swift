import Foundation

enum VSCodeServeWebLaunchAttemptResult {
    case launched(process: Process, url: URL)
    case failed(retryable: Bool)
}
