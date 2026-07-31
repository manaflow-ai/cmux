import Foundation

enum BrowserAutomationSnapshotResult: Sendable {
    case success(Data)
    case failure(code: String, message: String)
    case timedOut
}
