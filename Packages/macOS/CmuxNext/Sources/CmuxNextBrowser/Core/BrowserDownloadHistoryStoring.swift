package import Foundation

/// Private persistence used by the app's ended-download history model.
package nonisolated protocol BrowserDownloadHistoryStoring: Sendable {
    func read() throws -> Data?
    func write(_ data: Data) throws
    func remove() throws
}
