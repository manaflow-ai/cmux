import Foundation

/// Immutable search-result identities captured when a context menu opens.
final class FileExplorerSearchMenuSelection: NSObject {
    let clickedResult: FileSearchResult
    let selectedResults: [FileSearchResult]

    init(clickedResult: FileSearchResult, selectedResults: [FileSearchResult]) {
        self.clickedResult = clickedResult
        self.selectedResults = selectedResults.isEmpty ? [clickedResult] : selectedResults
    }
}
