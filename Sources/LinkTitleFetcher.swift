import CmuxBrowser
import Foundation

/// Coordinates workspace-owned title state with the browser networking service.
@MainActor
final class LinkTitleFetcher {
    private let pageMetadataFetcher: any BrowserPageMetadataFetching

    init(pageMetadataFetcher: any BrowserPageMetadataFetching) {
        self.pageMetadataFetcher = pageMetadataFetcher
    }

    func fetchTitleIfNeeded(
        for entry: WorkspaceCapturedLink,
        linksState: WorkspaceLinksState
    ) async {
        guard let url = URL(string: entry.url),
              let currentEntry = linksState.beginTitleFetch(for: entry.id) else {
            return
        }

        do {
            let title = try await pageMetadataFetcher.title(for: url)
            try Task.checkCancellation()
            linksState.finishTitleFetch(for: currentEntry.id, title: title)
        } catch is CancellationError {
            linksState.cancelTitleFetch(for: currentEntry.id)
        } catch {
            linksState.finishTitleFetch(for: currentEntry.id, title: nil)
        }
    }
}
