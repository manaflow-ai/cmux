import Foundation

/// Maps the built-in default profile to the shared ``BrowserHistoryStore`` and
/// builds a file-backed store for every other profile, conforming the concrete
/// history store to the ``BrowserProfileHistoryProviding`` seam the repository
/// consumes.
@MainActor
final class BrowserProfileHistoryAdapter: BrowserProfileHistoryProviding {
    var sharedHistoryStore: any BrowserProfileHistoryStore { BrowserHistoryStore.shared }

    func makeHistoryStore(fileURL: URL?) -> any BrowserProfileHistoryStore {
        BrowserHistoryStore(fileURL: fileURL)
    }

    func defaultHistoryFileURLForCurrentBundle() -> URL? {
        BrowserHistoryStore.defaultHistoryFileURLForCurrentBundle()
    }

    func normalizedBrowserHistoryNamespace(forBundleIdentifier bundleIdentifier: String) -> String {
        BrowserHistoryStore.normalizedBrowserHistoryNamespaceForBundleIdentifier(bundleIdentifier)
    }

    func flushSharedHistoryPendingSaves() {
        BrowserHistoryStore.shared.flushPendingSaves()
    }
}
