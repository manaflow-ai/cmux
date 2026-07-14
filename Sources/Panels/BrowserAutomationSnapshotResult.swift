import Foundation

enum BrowserAutomationSnapshotResult {
    case success(Data)
    case failure(String)
    case timedOut
}
