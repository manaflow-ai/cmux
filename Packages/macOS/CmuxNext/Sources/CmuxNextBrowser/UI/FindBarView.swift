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

    let pill: FindPillView
    private var findTask: Task<Void, Never>?

    /// The pill's material: glass, or opaque under Reduce Transparency.
    var glass: OverlaySurfaceView? { pill.surface }

    override init(frame: NSRect) {
        let size = Metrics.smallIconSize - 1
        let icons = FindPillIcons(search: .icon(.browserOmniboxSearch, size: size), previous: .icon(.browserFindPrevious, size: size),
                                  next: .icon(.browserFindNext, size: size), close: .icon(.actionClose, size: size))
        let labels = FindPillLabels(placeholder: Strings.findPlaceholder, previous: Strings.findPrevious, next: Strings.findNext,
                                    close: Strings.findDone, matchCase: Strings.findMatchCase)
        pill = FindPillView(labels: labels, icons: icons, accessibilityPrefix: "cmux.browser.find")
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(pill)
        NSLayoutConstraint.activate([
            pill.leadingAnchor.constraint(equalTo: leadingAnchor),
            pill.trailingAnchor.constraint(equalTo: trailingAnchor),
            pill.topAnchor.constraint(equalTo: topAnchor),
            pill.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
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

    private func run(_ direction: BrowserFindDirection) {
        findTask?.cancel()
        guard let tab else { return }
        let text = pill.query
        let caseSensitive = pill.matchCase
        findTask = Task { [weak self] in
            let result = await tab.find(text, direction: direction, caseSensitive: caseSensitive)
            guard !Task.isCancelled else { return }
            self?.show(result, for: text)
        }
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
