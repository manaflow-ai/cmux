import AppKit
import CmuxNextDesign
import CmuxNextIcons
import CmuxNextTerminalFind
import CmuxNextWakeups
import Observation

/// The inline find bar over a terminal's top-trailing corner: the shared
/// ``FindPillView`` (the same Liquid Glass capsule as the browser's and the
/// web pages' find), driven by ``TerminalFindController``. It renders the
/// controller and sends every edit, key and click to it. Ghostty matches
/// case-insensitively, so the pill has no match-case toggle here.
final class TerminalFindBarView: NSView {
    private let find: TerminalFindController
    let pill: FindPillView
    private var shownFocusRequest = 0
    /// Follows the controller: one render per frame however many of its values changed.
    private var watch: FrameObservation<Shown>?

    /// What the bar shows of its controller.
    private struct Shown: Equatable {
        var presented: Bool
        var query: String
        var count: TerminalFindCount
        var focusRequest: Int

        @MainActor init(_ find: TerminalFindController) {
            presented = find.isPresented
            query = find.query
            count = find.count
            focusRequest = find.focusRequest
        }
    }

    /// - Parameter mainWork: The app's main-thread scheduler the bar follows `find` through; nil (tests)
    ///   renders `find` once.
    init(find: TerminalFindController, mainWork: MainWorkScheduler?) {
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
        follow(on: mainWork)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

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

    /// Renders the controller now and once per frame after each change. The bar's own keys (typing,
    /// Return, Escape) are a person's changes: they render in that key's input-response pass.
    private func follow(on mainWork: MainWorkScheduler?) {
        let find = self.find
        guard let mainWork else { return render(Shown(find)) }
        // node-free: the bar has no VisibilityNode (its host has none); the apply only sets the pill.
        let watch = FrameObservation(owner: "Terminal.findBar", delivery: .visible(nil), on: mainWork) {
            Shown(find)
        } onChange: { [weak self] shown in
            self?.render(shown)
        }
        self.watch = watch
        render(watch.value)
    }

    private func render(_ shown: Shown) {
        let presented = shown.presented
        let query = shown.query
        let count = shown.count
        let focusRequest = shown.focusRequest

        pill.query = query
        let text = Self.text(for: count)
        if pill.countText != text { superview?.needsLayout = true } // the host frames the bar to its fitting width
        if case .noMatches = count {
            pill.showCount(text, noMatches: true)
        } else {
            pill.showCount(text, noMatches: false)
        }
        pill.setPresented(presented)
        if presented, focusRequest != shownFocusRequest {
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
        FindPillLabels(placeholder: placeholder, previous: previousLabel, next: nextLabel, close: closeLabel)
    }

    // MARK: Strings

    private static func text(for count: TerminalFindCount) -> String {
        switch count {
        case .empty:
            return ""
        case .noMatches:
            return String(localized: "terminal.find.noMatches", defaultValue: "No matches", bundle: .module)
        case .position(let index, let total):
            return String(localized: "terminal.find.position", defaultValue: "\(index) of \(total)", bundle: .module)
        }
    }

    private static var placeholder: String {
        String(localized: "terminal.find.placeholder", defaultValue: "Find", bundle: .module)
    }

    private static var previousLabel: String {
        String(localized: "terminal.find.previous", defaultValue: "Previous Match", bundle: .module)
    }

    private static var nextLabel: String {
        String(localized: "terminal.find.next", defaultValue: "Next Match", bundle: .module)
    }

    private static var closeLabel: String {
        String(localized: "terminal.find.close", defaultValue: "Close", bundle: .module)
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
