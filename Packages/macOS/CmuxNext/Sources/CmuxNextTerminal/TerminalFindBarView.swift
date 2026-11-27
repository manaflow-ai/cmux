import AppKit
import CmuxNextDesign
import CmuxNextIcons
import CmuxNextTerminalFind
import Observation

/// The inline find bar over a terminal's top-trailing corner: the shared
/// ``FindPillView`` (the same Liquid Glass capsule as the browser's and the
/// web pages' find), driven by ``TerminalFindController``. It renders the
/// controller and sends every edit, key and click to it. While the daemon
/// searches the whole history the pill has case, whole-word and regex toggles;
/// Ghostty's screen search has none, so a terminal without the daemon's search
/// hides them.
final class TerminalFindBarView: NSView {
    private let find: TerminalFindController
    let pill: FindPillView
    private var shownFocusRequest = 0

    init(find: TerminalFindController) {
        self.find = find
        pill = FindPillView(labels: Self.labels, icons: .terminal, accessibilityPrefix: "cmux.terminal.find")
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(pill)
        NSLayoutConstraint.activate([
            pill.leadingAnchor.constraint(equalTo: leadingAnchor),
            pill.trailingAnchor.constraint(equalTo: trailingAnchor),
            pill.topAnchor.constraint(equalTo: topAnchor),
            pill.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        pill.onQueryChange = { [weak self] in self?.find.updateQuery($0) }
        pill.onCommand = { [weak self] in self?.run($0) }
        pill.onMatchCaseChange = { [weak self] in self?.find.setOption(\.caseSensitive, $0) }
        pill.onWholeWordChange = { [weak self] in self?.find.setOption(\.wholeWord, $0) }
        pill.onRegexChange = { [weak self] in self?.find.setOption(\.regex, $0) }
        observe()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Renders the controller's state now, without waiting for observation's
    /// main-actor hop: the host calls it in the event that opened find.
    func update() {
        render()
    }

    /// A focus request made while the bar had no window is served here.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { render() }
    }

    /// Clicks pass through to the terminal while the pill is hidden.
    override func hitTest(_ point: NSPoint) -> NSView? {
        pill.isHidden ? nil : super.hitTest(point)
    }

    /// Cmd-G and Shift-Cmd-G while the field has the keyboard (app
    /// shortcuts skip a focused text input). With the terminal focused,
    /// Find Next and Find Previous arrive as registry actions instead.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard pill.isPresented, pill.isEditing, let command = Self.command(for: event), command != .close else {
            return super.performKeyEquivalent(with: event)
        }
        run(command)
        return true
    }

    // MARK: Rendering

    /// Re-renders whenever the controller state it reads changes.
    private func observe() {
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func render() {
        let presented = find.isPresented
        let query = find.query
        let count = find.count
        let focusRequest = find.focusRequest

        pill.query = query
        let text = Self.text(for: count)
        if pill.countText != text { superview?.needsLayout = true } // the host frames the bar to its fitting width
        switch count {
        case .noMatches:
            pill.showCount(text, noMatches: true)
            pill.setCountDetail(nil)
        case .invalidPattern(let reason):
            pill.showCount(text, noMatches: true, canStep: false)
            pill.setCountDetail(reason)
        default:
            pill.showCount(text, noMatches: false)
            pill.setCountDetail(nil)
        }
        pill.setTogglesVisible(find.offersOptions)
        pill.matchCase = find.options.caseSensitive
        pill.wholeWord = find.options.wholeWord
        pill.regex = find.options.regex
        pill.setPresented(presented)
        // Kept pending until the bar is in a window: making a field first
        // responder there is a no-op, and the request would be lost.
        if presented, focusRequest != shownFocusRequest, window != nil {
            shownFocusRequest = focusRequest
            pill.focusField()
        }
    }

    // MARK: Actions

    private func run(_ command: TerminalFindKeyCommand) {
        switch command {
        case .next: find.navigate(.next)
        case .previous: find.navigate(.previous)
        case .close: find.close()
        }
    }

    private func run(_ command: FindPillCommand) {
        switch command {
        case .next: find.navigate(.next)
        case .previous: find.navigate(.previous)
        case .close: find.close()
        }
    }

    private static func command(for event: NSEvent) -> TerminalFindKeyCommand? {
        var modifiers: TerminalFindKeyCommand.Modifiers = []
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        return TerminalFindKeyCommand(key: event.charactersIgnoringModifiers ?? "", modifiers: modifiers)
    }

    private static var labels: FindPillLabels {
        FindPillLabels(placeholder: placeholder, previous: previousLabel, next: nextLabel, close: closeLabel,
                       matchCase: String(localized: "terminal.find.matchCase", defaultValue: "Match Case", bundle: .localizedModule),
                       wholeWord: String(localized: "terminal.find.wholeWord", defaultValue: "Match Whole Word", bundle: .localizedModule),
                       regex: String(localized: "terminal.find.regex", defaultValue: "Use Regular Expression", bundle: .localizedModule))
    }

    // MARK: Strings

    private static func text(for count: TerminalFindCount) -> String {
        switch count {
        case .empty:
            return ""
        case .noMatches:
            return String(localized: "terminal.find.noMatches", defaultValue: "No matches", bundle: .localizedModule)
        case .position(let index, let total):
            return String(localized: "terminal.find.position", defaultValue: "\(index) of \(total)", bundle: .localizedModule)
        case .partial(let index, let total):
            return String(localized: "terminal.find.positionPartial", defaultValue: "\(index) of \(total)+", bundle: .localizedModule)
        case .invalidPattern:
            return String(localized: "terminal.find.invalidPattern", defaultValue: "Invalid pattern", bundle: .localizedModule)
        }
    }

    private static var placeholder: String {
        String(localized: "terminal.find.placeholder", defaultValue: "Find", bundle: .localizedModule)
    }

    private static var previousLabel: String {
        String(localized: "terminal.find.previous", defaultValue: "Previous Match", bundle: .localizedModule)
    }

    private static var nextLabel: String {
        String(localized: "terminal.find.next", defaultValue: "Next Match", bundle: .localizedModule)
    }

    private static var closeLabel: String {
        String(localized: "terminal.find.close", defaultValue: "Close", bundle: .localizedModule)
    }
}

private extension FindPillIcons {
    /// The icons every find pill draws (the browser's are the same names).
    static var terminal: FindPillIcons {
        let size = Metrics.smallIconSize - 1
        return FindPillIcons(search: .icon(.browserOmniboxSearch, size: size), previous: .icon(.browserFindPrevious, size: size),
                             next: .icon(.browserFindNext, size: size), close: .icon(.actionClose, size: size))
    }
}
