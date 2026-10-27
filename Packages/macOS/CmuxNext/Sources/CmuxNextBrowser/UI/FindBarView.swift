import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// Find in page: the shared ``FindPillView`` (the same Liquid Glass capsule as
/// the terminal's and the web pages' find) over the engine's find. Enter finds
/// the next match, Shift-Enter the previous one, Escape closes; the Aa toggle
/// matches case. The chrome view shows and hides this container.
final class FindBarView: NSView {
    var onClose: (() -> Void)?
    weak var tab: (any BrowserTab)?
    /// What the bar searches for and the engine's last answer (its chrome view's).
    let model: BrowserFindModel

    let pill: FindPillView
    /// The current search; tests await it.
    private(set) var findTask: Task<Void, Never>?

    /// The pill's material: glass, or opaque under Reduce Transparency.
    var glass: OverlaySurfaceView? { pill.surface }

    init(model: BrowserFindModel) {
        self.model = model
        let size = Metrics.smallIconSize - 1
        let icons = FindPillIcons(search: .icon(.browserOmniboxSearch, size: size), previous: .icon(.browserFindPrevious, size: size),
                                  next: .icon(.browserFindNext, size: size), close: .icon(.actionClose, size: size))
        let labels = FindPillLabels(placeholder: Strings.findPlaceholder, previous: Strings.findPrevious, next: Strings.findNext,
                                    close: Strings.findDone, matchCase: Strings.findMatchCase)
        pill = FindPillView(labels: labels, icons: icons, accessibilityPrefix: "cmux.browser.find")
        super.init(frame: .zero)
        // The pill fills this container by its autoresizing mask: its own
        // constraints (FindPillView) size it, and through the mask this
        // container, wherever the chrome places it.
        pill.translatesAutoresizingMaskIntoConstraints = true
        pill.autoresizingMask = [.width, .height]
        pill.frame = bounds
        addSubview(pill)
        // This container fades in and out (BrowserChromeView); the pill stays shown inside it.
        pill.setPresented(true)
        pill.onQueryChange = { [weak self] _ in self?.run(.forward) }
        pill.onMatchCaseChange = { [weak self] _ in self?.run(.forward) }
        pill.onCommand = { [weak self] command in
            switch command {
            case .next: self?.findNext()
            case .previous: self?.findPrevious()
            case .close: self?.close()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func focus() {
        pill.focusField()
        if !pill.query.isEmpty { run(.forward) }
    }

    @objc func findNext() { run(.forward) }
    @objc func findPrevious() { run(.backward) }

    @objc func close() {
        findTask?.cancel()
        tab?.clearFind()
        onClose?()
    }

    /// One search. An engine that reports every result (``BrowserFindUpdating``: Chromium's
    /// FIND_RESULT events) updates the pill with each, else the pill shows the answer.
    private func run(_ direction: BrowserFindDirection) {
        findTask?.cancel()
        guard let tab else { return }
        let text = pill.query
        let caseSensitive = pill.matchCase
        model.setQuery(text)
        // main-hop-allow: the person's find keystroke; find is BrowserTab's main-actor async engine call (the search runs in the page's process); this task only starts it and shows its answer
        findTask = Task { [weak self] in
            let result: BrowserFindResult
            if let updating = tab as? any BrowserFindUpdating {
                var updated = false
                result = await updating.find(text, direction: direction, caseSensitive: caseSensitive) { [weak self] update in
                    updated = true
                    self?.apply(update, for: text, caseSensitive: caseSensitive)
                }
                // The updates are the only writer once one came: the answer is the first final
                // result, and a later one of the same search may already have corrected it.
                guard !updated else { return }
            } else {
                result = await tab.find(text, direction: direction, caseSensitive: caseSensitive)
            }
            guard !Task.isCancelled, let self else { return }
            apply(result, for: text, caseSensitive: caseSensitive)
        }
    }

    /// Shows a result of the search for `text`; one of an earlier search (the query or the case
    /// toggle changed since) shows nothing.
    private func apply(_ result: BrowserFindResult, for text: String, caseSensitive: Bool) {
        guard text == pill.query, caseSensitive == pill.matchCase else { return }
        model.record(result, for: text)
        show(result, for: text)
    }

    private func show(_ result: BrowserFindResult, for text: String) {
        if text.isEmpty {
            pill.showCount("", noMatches: false)
        } else if !result.matchFound {
            pill.showCount(Strings.findNoMatches, noMatches: true)
        } else if let index = result.currentIndex, let count = result.matchCount {
            pill.showCount(Strings.findPosition(index, of: count), noMatches: false)
        } else if let count = result.matchCount {
            pill.showCount(Strings.findCount(count), noMatches: false)
        } else {
            pill.showCount("", noMatches: false, canStep: true)
        }
    }
}
