public import Foundation

/// The production ``DeepLinkRouting``, lifted byte-for-byte from the
/// URL-partitioning lines of AppDelegate's `application(_:open:)`.
///
/// It builds the terminal-eligible requests with
/// ``TerminalDefaultFileOpenRequest/requests(from:)``, then removes the files
/// those requests already cover from the file-preview set by comparing
/// standardized, percent-decoded paths, and carries the directories through
/// unchanged.
///
/// Design: the planner holds no state and does pure URL string partitioning
/// with no main-bound (AppKit/window) work, so it is a `Sendable`,
/// `nonisolated` value type with instance methods (a real instance constructed
/// at the composition root and injected as ``DeepLinkRouting``), not a
/// static-method namespace and not `@MainActor` (it never touches main state).
public struct DeepLinkOpenPlanner: DeepLinkRouting {
    /// Creates a deep-link open planner.
    public init() {}

    /// Builds the open plan; see ``DeepLinkRouting/openPlan(externalFileURLs:directories:)``
    /// for the contract.
    public func openPlan(
        externalFileURLs: [URL],
        directories: [String]
    ) -> DeepLinkOpenPlan {
        let terminalFileRequests = TerminalDefaultFileOpenRequest.requests(from: externalFileURLs)
        let terminalFilePaths = Set(terminalFileRequests.map { $0.fileURL.path(percentEncoded: false) })
        let filePreviewPaths = externalFileURLs
            .filter { url in
                !terminalFilePaths.contains(url.standardizedFileURL.path(percentEncoded: false))
            }
            .map { $0.path(percentEncoded: false) }
        return DeepLinkOpenPlan(
            terminalFileRequests: terminalFileRequests,
            filePreviewPaths: filePreviewPaths,
            directories: directories
        )
    }
}
