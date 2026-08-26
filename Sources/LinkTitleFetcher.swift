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
              let request = linksState.beginTitleFetch(for: entry.id) else {
            return
        }

        do {
            let title = try await pageMetadataFetcher.title(for: url)
            try Task.checkCancellation()
            linksState.finishTitleFetch(
                for: request.entry.id,
                requestID: request.requestID,
                title: title
            )
        } catch is CancellationError {
            linksState.cancelTitleFetch(
                for: request.entry.id,
                requestID: request.requestID
            )
        } catch {
            linksState.finishTitleFetch(
                for: request.entry.id,
                requestID: request.requestID,
                title: nil
            )
        }
    }
}
