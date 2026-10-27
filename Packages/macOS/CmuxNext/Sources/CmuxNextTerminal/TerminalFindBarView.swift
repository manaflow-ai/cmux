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
    private(set) var watch: FrameObservation<Shown>?
    /// The scheduler's causes: the bar's own edits run as the person's (``asPerson(_:)``).
    private let causes: ObservationCauses

    /// What the bar shows of its controller.
    struct Shown: Equatable {
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

    /// - Parameters:
    ///   - mainWork: The app's main-thread scheduler the bar follows `find` through.
    ///   - node: The terminal host's node (``TerminalHostView/node``): hidden, the bar follows nothing
    ///     and reads once when it shows.
    init(find: TerminalFindController, mainWork: MainWorkScheduler, node: VisibilityNode?) {
        self.find = find
        causes = mainWork.causes
        let pill = FindPillView(labels: Self.labels, icons: .terminal, accessibilityPrefix: "cmux.terminal.find")
        self.pill = pill
        super.init(frame: CGRect(origin: .zero, size: pill.fittingSize))
        // Framed in layout(); the pill's content keeps its own constraints, so it starts at the size they ask for.
        pill.translatesAutoresizingMaskIntoConstraints = true
        pill.frame = bounds
        addSubview(pill)
        pill.onQueryChange = { [weak self] query in self?.asPerson { $0.find.updateQuery(query) } }
        pill.onCommand = { [weak self] command in self?.asPerson { $0.run(command) } }
        follow(on: mainWork, node: node)
    }

    /// Runs a change the person made in the bar (a key in its field, a click on its buttons) as theirs,
    /// so the bar's render runs in that input's response pass, before its commit.
    private func asPerson(_ change: (TerminalFindBarView) -> Void) {
        causes.withCause(.person) { change(self) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The pill's own size (its field's preferred width, its fixed height); the host frames the bar
    /// at it, no wider than its room (`TerminalHostView.layoutOverlays`).
    override var fittingSize: NSSize { pill.fittingSize }

    override func setFrameSize(_ newSize: NSSize) {
        let oldSize = frame.size
        super.setFrameSize(newSize)
        if newSize != oldSize { needsLayout = true } // invalidate: a new size (the check above) re-frames the pill
    }

    /// The pill fills the bar.
    override func layout() {
        super.layout()
        if pill.frame != bounds { pill.frame = bounds }
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
        asPerson { $0.run(command) }
        return true
    }

    // MARK: Rendering

    /// Renders the controller now and once per frame after each change. The bar's own edits and
    /// clicks run as the person's (``asPerson(_:)``): they render in that input's response pass.
    private func follow(on mainWork: MainWorkScheduler, node: VisibilityNode?) {
        let find = self.find
        let watch = FrameObservation(owner: "Terminal.findBar", delivery: .visible(node), on: mainWork) {
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
