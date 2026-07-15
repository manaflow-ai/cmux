import Foundation

enum BrowserAutomationSnapshotResult: Sendable {
    case success(Data)
    case failure(String)
    case timedOut
}
