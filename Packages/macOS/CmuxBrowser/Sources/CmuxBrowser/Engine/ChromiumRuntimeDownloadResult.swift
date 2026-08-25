import Foundation

/// Immutable URLSession result transferred across the download task boundary.
// SAFETY: both Foundation values are published only after URLSession finishes
// and are never mutated by the receiving task.
struct ChromiumRuntimeDownloadResult: @unchecked Sendable {
    let archiveURL: URL
    let response: URLResponse
}
