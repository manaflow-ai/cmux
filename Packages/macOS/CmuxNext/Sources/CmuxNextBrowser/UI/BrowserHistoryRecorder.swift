import Foundation

/// Records a tab's finished navigations into a history store. The App layer
/// keeps one per tab, including background tabs that have no chrome.
public final class BrowserHistoryRecorder {
    private let store: any BrowserHistoryStore
    private weak var tab: (any BrowserTab)?
    private var observation: ObservationLoop?
    private var lastURL: URL?

    public init(tab: any BrowserTab, store: any BrowserHistoryStore) {
        self.tab = tab
        self.store = store
        observation = ObservationLoop { [weak self] in self?.record() }
    }

    public func stop() {
        observation?.cancel()
        observation = nil
    }

    private func record() {
        guard let state = tab?.state else { return }
        guard state.phase == .finished, let url = state.url else { return }
        if url != lastURL {
            lastURL = url
            store.recordVisit(url: url, title: state.title, at: Date())
        } else if let title = state.title {
            store.updateTitle(title, for: url)
        }
    }
}
