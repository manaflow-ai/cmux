import CmuxNextFiles

/// A Files tab's folder history as page history, so cmux's Back and Forward
/// (Cmd+[ and Cmd+]) step through the folders the tab showed.
@MainActor
final class FilesPaneHistory: PageHistory {
    private let model: FileBrowserModel

    init(model: FileBrowserModel) { self.model = model }

    var canGoBack: Bool { model.canGoBack }
    var canGoForward: Bool { model.canGoForward }

    @discardableResult
    func goBack() -> Bool {
        guard model.canGoBack else { return false }
        // main-hop-allow: the person's Back, userBlocking rest (p06 rule 2): goBack is FileBrowserModel's main-actor async listing (off main); this task only starts it
        Task { await model.goBack() }
        return true
    }

    @discardableResult
    func goForward() -> Bool {
        guard model.canGoForward else { return false }
        // main-hop-allow: the person's Forward, userBlocking rest (p06 rule 2): goForward is FileBrowserModel's main-actor async listing (off main); this task only starts it
        Task { await model.goForward() }
        return true
    }
}
