import Foundation

extension MarkdownPanel {
    var searchState: MarkdownSearchState? {
        findController.searchState
    }

    func startFind() {
        guard displayMode == .preview, !isFileUnavailable else { return }
        findController.startFind()
    }

    @discardableResult
    func updateFindNeedle(_ needle: String) -> Task<Void, Never>? {
        findController.updateNeedle(needle)
    }

    @discardableResult
    func findNext() -> Task<Void, Never>? {
        findController.findNext()
    }

    @discardableResult
    func findPrevious() -> Task<Void, Never>? {
        findController.findPrevious()
    }

    @discardableResult
    func hideFind() -> Task<Void, Never>? {
        guard searchState != nil else { return nil }
        let task = findController.hideFind()
        rendererSession.focusWebView()
        return task
    }
}
