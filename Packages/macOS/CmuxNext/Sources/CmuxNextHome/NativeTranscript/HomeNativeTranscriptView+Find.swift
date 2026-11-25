public import AppKit
public import CmuxNextDesign
import CmuxNextDesignTokens
import CmuxNextIcons
import MessagesLabHome

/// Find in this chat (Cmd-F): the shared find pill (``FindPillView``, the terminal's, the browser's
/// and the web pages' capsule) over the transcript's top-trailing corner, under the header. It
/// searches as the person types, case-insensitive like the agent chat's Find in Chat; Return and
/// Cmd-G step forward, Shift-Return and Shift-Cmd-G back, Escape closes it and gives the keyboard
/// back to the message box. The pill is made on the first find, not with the chat.
extension HomeNativeTranscriptView {
    /// The first Home transcript in `view` or under it (a Home tab, the dock, a conversation tab).
    public static func first(in view: NSView) -> HomeNativeTranscriptView? {
        var stack = [view]
        while let next = stack.popLast() {
            if let home = next as? HomeNativeTranscriptView { return home }
            stack.append(contentsOf: next.subviews)
        }
        return nil
    }

    /// The find pill while one was made (``showFind(text:takeFocus:)``).
    public var findBar: FindPillView? { findPill }

    /// Opens Find (Cmd-F): with `text` as the query when given, else the last one, searched again.
    /// `takeFocus` gives the field the keyboard with its text selected (a person's Cmd-F; a socket run does not).
    public func showFind(text: String? = nil, takeFocus: Bool) {
        let pill = findPill ?? makeFindPill()
        if let text { pill.query = text }
        pill.setPresented(true)
        layoutFind()
        updateFindCount(transcript.find(pill.query))
        if takeFocus { pill.focusField() }
    }

    /// Find Next (`forward`) or Find Previous; opens Find with the last query when it is closed.
    public func stepFind(forward: Bool, takeFocus: Bool) {
        guard let pill = findPill, pill.isPresented else { return showFind(takeFocus: takeFocus) }
        updateFindCount(transcript.findStep(forward: forward))
    }

    /// Closes Find and clears its highlights; `restoringFocus` gives the keyboard back to the message box.
    public func hideFind(restoringFocus: Bool) {
        guard let pill = findPill, pill.isPresented else { return }
        let hadKeyboard = FindPillView.ownsFieldEditor(window?.firstResponder)
        pill.setPresented(false)
        transcript.find("")
        if restoringFocus || hadKeyboard { transcript.focusPrimaryInputForTyping() }
    }

    /// The messages changed while Find shows: the count follows them.
    func findRowsChanged() {
        guard let pill = findPill, pill.isPresented, !pill.query.isEmpty else { return }
        updateFindCount(transcript.findRowsChanged())
    }

    /// Top-trailing, under the header (and the section pinned under it).
    func layoutFind() {
        guard let pill = findPill, !pill.isHidden else { return }
        let fitting = pill.fittingSize
        let inset = 12 * Self.chatScale
        let width = max(0, min(fitting.width, bounds.width - 2 * inset))
        let frame = CGRect(x: bounds.width - width - inset, y: transcript.headerHeight + pinnedSectionClearance + 8,
                           width: width, height: fitting.height).integral
        if pill.frame != frame { pill.frame = frame }
    }

    private func makeFindPill() -> FindPillView {
        let pill = FindPillView(labels: Self.findLabels, icons: Self.findIcons, accessibilityPrefix: "cmux.home.find")
        pill.translatesAutoresizingMaskIntoConstraints = true // framed in layoutFind()
        pill.onQueryChange = { [weak self] query in self?.updateFindCount(self?.transcript.find(query) ?? (0, 0)) }
        pill.onCommand = { [weak self] command in
            guard let self else { return }
            switch command {
            case .next: self.updateFindCount(self.transcript.findStep(forward: true))
            case .previous: self.updateFindCount(self.transcript.findStep(forward: false))
            case .close: self.hideFind(restoringFocus: true)
            }
        }
        addSubview(pill)
        findPill = pill
        return pill
    }

    private func updateFindCount(_ position: (current: Int, total: Int)) {
        guard let pill = findPill else { return }
        if pill.query.isEmpty {
            pill.showCount("", noMatches: false)
        } else if position.total == 0 {
            pill.showCount(String(localized: "home.find.noMatches", defaultValue: "No matches", bundle: .localizedModule), noMatches: true)
        } else {
            pill.showCount(String(localized: "home.find.position", defaultValue: "\(position.current) of \(position.total)", bundle: .localizedModule),
                           noMatches: false)
        }
        layoutFind()
    }

    private static var findLabels: FindPillLabels {
        FindPillLabels(placeholder: String(localized: "home.find.placeholder", defaultValue: "Find", bundle: .localizedModule),
                       previous: String(localized: "home.find.previous", defaultValue: "Previous Match", bundle: .localizedModule),
                       next: String(localized: "home.find.next", defaultValue: "Next Match", bundle: .localizedModule),
                       close: String(localized: "home.find.close", defaultValue: "Close", bundle: .localizedModule))
    }

    /// The icons every find pill draws.
    private static var findIcons: FindPillIcons {
        let size = Metrics.smallIconSize - 1
        return FindPillIcons(search: .icon(.browserOmniboxSearch, size: size), previous: .icon(.browserFindPrevious, size: size),
                             next: .icon(.browserFindNext, size: size), close: .icon(.actionClose, size: size))
    }
}
