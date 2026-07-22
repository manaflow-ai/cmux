import Foundation

/// Closure actions let a viewer page mutate its owner without retaining an observable model.
struct ChatArtifactViewerPageActions {
    let load: @MainActor () async -> Void
    let cleanup: @MainActor () async -> Void
    let retry: @MainActor () -> Void
    let setSearchQuery: @MainActor (String) -> Void
    let setSearchSummary: @MainActor (ChatArtifactSearchSummary) -> Void
    let selectPreviousSearchResult: @MainActor () -> Void
    let selectNextSearchResult: @MainActor () -> Void
    let dismissSearch: @MainActor () -> Void
    let setGoToLineText: @MainActor (String) -> Void
    let goToLine: @MainActor (Int) -> Void
    let dismissGoToLine: @MainActor () -> Void
    let setFontSize: @MainActor (Double) -> Void
}
