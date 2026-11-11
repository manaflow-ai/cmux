public import AppKit
import CmuxNextDesign

/// Small label over a terminal whose link is down: the last screen stays
/// visible behind it. The theme's raised surface and secondary text, no
/// accent. ``TerminalStatusLabel`` builds it the first time a label shows and
/// decides when it shows; it starts hidden.
///
/// An in-between state ("Restoring…", "Reconnecting…": the ones that wait out a
/// reveal delay) is no label at all: a small, very transparent loading mark with
/// no surface of its own, so the pane keeps its one material (Leo, 2026-11-07:
/// "we can just have the small symbols as loading indicators, like really
/// transparent things"). Its words stay its accessibility label.
///
/// A pane that still starts after ``startingOverdueDelay`` says so in words and offers Close after
/// them (``show(_:inBetween:fadeIn:closes:)``): the one control in the label that takes a click.
final class TerminalStatusBanner: NSView {
    private let label = ThemedLabel(labelWithString: "")
    /// The in-between state's mark, built the first time one shows.
    private var mark: StatusIndicatorView?
    private lazy var labelTrailing = label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12)
    private lazy var labelEdges = [
        label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
        labelTrailing,
        label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
        label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
    ]
    private var markEdges: [NSLayoutConstraint] = []
    /// Close after the words, built the first time it is offered. No key hint: a hint binds its key
    /// for the whole window, two starting panes would bind the same one, and Return and Escape are
    /// the terminal's keys. Close Tab's shortcut closes the focused pane as always.
    private var closeButton: ThemedBezelButton?
    private var closeEdges: [NSLayoutConstraint] = []
    /// Whether Close shows after the words.
    private(set) var offersClose = false
    /// Close was pressed.
    var onClose: (@MainActor () -> Void)?
    /// Whether it shows the in-between mark instead of its words.
    private(set) var showsMark = false
    /// The mark's side, the size of a tab's loading mark.
    static let markSide: CGFloat = 14
    /// The mark's opacity: present, never louder than the terminal under it.
    static let markOpacity: CGFloat = 0.4

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Metrics.surfaceCornerRadius
        layer?.borderWidth = Metrics.lineWidth(1)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.ink = .secondary
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate(labelEdges)
        isHidden = true
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyThemeColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyThemeColors()
    }

    private func applyThemeColors() {
        guard !showsMark else {
            layer?.backgroundColor = nil
            layer?.borderColor = nil
            return
        }
        performWithTheme {
            layer?.backgroundColor = Palette.elevatedBackground.cgColor
            layer?.borderColor = Palette.separator.cgColor
            closeButton?.contentTintColor = Palette.textSecondary
        }
        // As the "Sized for" chip's button: its title draws for its own appearance, so it takes the theme's.
        guard let closeButton else { return }
        let dark = themeTokens.isDark
        let isDark = closeButton.appearance.map { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
        if isDark != dark { closeButton.appearance = NSAppearance(named: dark ? .darkAqua : .aqua) }
    }

    /// Shows or takes away Close after the words (never with the mark).
    private func setOffersClose(_ offers: Bool) {
        guard offers != offersClose else { return }
        offersClose = offers
        if offers { buildCloseButton() }
        closeButton?.isHidden = !offers
        setAccessibilityRole(offers ? .group : .staticText)
        if offers {
            labelTrailing.isActive = false
            NSLayoutConstraint.activate(closeEdges)
            applyThemeColors()
        } else {
            NSLayoutConstraint.deactivate(closeEdges)
            labelTrailing.isActive = !showsMark
        }
    }

    private func buildCloseButton() {
        guard closeButton == nil else { return }
        let made = ThemedBezelButton(frame: .zero)
        made.title = Self.closeTitle()
        made.bezelStyle = .rounded
        made.controlSize = .small
        made.font = .systemFont(ofSize: TypeScale.caption, weight: TypeScale.emphasis)
        made.target = self
        made.action = #selector(closeClicked)
        made.translatesAutoresizingMaskIntoConstraints = false
        // In a narrow pane the words truncate before Close does.
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(made)
        closeEdges = [
            made.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            made.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            made.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(greaterThanOrEqualTo: made.heightAnchor, constant: 6),
        ]
        closeButton = made
    }

    @objc private func closeClicked() { onClose?() }

    /// The title of the Close on screen, nil while none is offered.
    var shownCloseTitle: String? { offersClose && !isHidden ? closeButton?.title : nil }

    /// Presses Close as a click on it does; false while it is not offered (tests).
    func pressClose() -> Bool {
        guard offersClose, !isHidden else { return false }
        closeClicked()
        return true
    }

    /// Shows the in-between mark (`mark`) or the words, and spins the mark only while it shows.
    private func setShowsMark(_ mark: Bool) {
        guard mark != showsMark else { return spinMark() }
        showsMark = mark
        if mark { buildMark() }
        NSLayoutConstraint.deactivate(mark ? labelEdges : markEdges)
        NSLayoutConstraint.activate(mark ? markEdges : labelEdges)
        label.isHidden = mark
        self.mark?.isHidden = !mark
        layer?.borderWidth = mark ? 0 : Metrics.lineWidth(1)
        applyThemeColors()
        spinMark()
    }

    private func buildMark() {
        guard mark == nil else { return }
        let made = StatusIndicatorView.spinner()
        made.translatesAutoresizingMaskIntoConstraints = false
        made.alphaValue = Self.markOpacity
        made.setAccessibilityElement(false)
        addSubview(made)
        let pad: CGFloat = 4
        markEdges = [
            made.widthAnchor.constraint(equalToConstant: Self.markSide),
            made.heightAnchor.constraint(equalToConstant: Self.markSide),
            made.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            made.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            made.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            made.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),
        ]
        mark = made
    }

    /// The mark spins while it shows and stops when it hides or gives way to words.
    private func spinMark() {
        mark?.spin(showsMark && !isHidden)
    }

    /// Clicks go to the terminal below (a click there re-attaches); only an offered Close takes one.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard offersClose, let closeButton else { return nil }
        let hit = super.hitTest(point)
        return hit?.isDescendant(of: closeButton) == true ? hit : nil
    }

    /// Shows `text` (the label's words, ``text(for:hostLoss:cause:stall:strings:)``); `inBetween`: as the
    /// in-between mark. `fadeIn`: it appears with the overlays' fade (a label that waited out its reveal
    /// delay); else at once. `closes`: Close shows after the words (never with the mark).
    func show(_ text: String, inBetween: Bool, fadeIn: Bool, closes: Bool = false) {
        setText(text, inBetween: inBetween, closes: closes)
        guard isHidden else { return }
        isHidden = false
        spinMark()
        if fadeIn, let layer { Motion.overlays.set(layer, "opacity", to: Float(1), fade: .fadeIn, from: Float(0)) }
    }

    /// Sets the words while hidden (a label still waiting, whose place the buttons above it use).
    func setText(_ text: String, inBetween: Bool, closes: Bool = false) {
        label.stringValue = text
        setAccessibilityLabel(text)
        let closes = closes && !inBetween
        if !closes { setOffersClose(false) }
        setShowsMark(inBetween)
        if closes { setOffersClose(true) }
    }

    func hide() {
        guard !isHidden else { return }
        layer?.removeAnimation(forKey: "opacity")
        isHidden = true
        spinMark()
    }

    /// Whether `status` (with the daemon's `stall`) is an in-between state, shown as the mark: one that waits
    /// out a reveal delay (``revealDelay(for:stall:)``) because it usually clears on its own.
    static func isInBetween(_ status: TerminalConnectionStatus, stall: TerminalShellStall?) -> Bool {
        revealDelay(for: status, stall: stall) != nil
    }

    /// "Restoring…" shows only after `restoringRevealDelay`, so an attach
    /// that answers at once (the usual case) never flashes the label.
    static let restoringRevealDelay: CFTimeInterval = 0.5
    /// "Reconnecting…" and "Reconnecting to the shell…" show only after
    /// `reconnectingRevealDelay`: a version handoff marks every tab adopting
    /// while the new daemon takes its host back (a slow host costs up to 1 s
    /// of connect retries and 2 s of handshake, after up to 2 s waiting for
    /// the owner to say ready), and a dropped view re-attaches at once. Those
    /// clear within it and never show; one that lasts still shows, and the
    /// lasting "Disconnected" and stopped states show at once.
    static let reconnectingRevealDelay: CFTimeInterval = 5
    /// A new pane's "Starting…" mark shows only after `startingRevealDelay`: the daemon confirms a
    /// split or a tab well within it, so the usual one never shows a mark.
    static let startingRevealDelay: CFTimeInterval = 1
    /// A pane that still starts this long after it began says so in words, with Close
    /// (``overdueText(for:stall:strings:)``). Nothing is rolled back: the pane stays and still waits.
    static let startingOverdueDelay: CFTimeInterval = 10

    /// How long the label for `status` (with the daemon's `stall`) waits
    /// before it fades in; nil shows it at once. Only transient states wait.
    static func revealDelay(for status: TerminalConnectionStatus, stall: TerminalShellStall?) -> CFTimeInterval? {
        if let stall = shownStall(status, stall) {
            return stall == .reconnecting ? reconnectingRevealDelay : nil
        }
        switch status {
        case .restoring: return restoringRevealDelay
        case .starting: return startingRevealDelay
        case .disconnected(.turnedOffByOrganization, _): return nil
        case .disconnected(_, reconnecting: true): return reconnectingRevealDelay
        case .connected, .disconnected, .exited: return nil
        }
    }

    /// How long after `status` began its label says ``overdueText(for:stall:strings:)`` instead, with
    /// Close; nil: it never does. Only a pane that still starts does, and never under a stall the label names.
    static func overdueDelay(for status: TerminalConnectionStatus, stall: TerminalShellStall?) -> CFTimeInterval? {
        status == .starting && shownStall(status, stall) == nil ? startingOverdueDelay : nil
    }

    /// The words of a `status` that lasted past ``overdueDelay(for:stall:)``, nil when it has none. They
    /// name the session, never the person's shell: no shell has started yet.
    static func overdueText(
        for status: TerminalConnectionStatus, stall: TerminalShellStall? = nil, strings: ModuleResourceBundle = .terminal
    ) -> String? {
        guard overdueDelay(for: status, stall: stall) != nil else { return nil }
        return strings.text("terminal.link.startingOverdue", defaultValue: "Still starting. The session is not answering.")
    }

    /// The title of Close in a pane that still starts.
    static func closeTitle(strings: ModuleResourceBundle = .terminal) -> String {
        strings.text("terminal.link.startingClose", defaultValue: "Close")
    }

    /// The banner text, or nil while connected. An exited terminal whose
    /// host was lost (`hostLoss`) says so, followed by the owner's recorded
    /// `cause` when there is one. A shell the daemon cannot reach (`stall`)
    /// is named whatever the view's own link says, unless it exited or an
    /// administrator turned the link off.
    /// `strings` defaults to this module's table and falls back to English
    /// if the bundle is gone.
    static func text(
        for status: TerminalConnectionStatus,
        hostLoss: TerminalHostLoss? = nil,
        cause: TerminalHostLossCause? = nil,
        stall: TerminalShellStall? = nil,
        strings: ModuleResourceBundle = .terminal
    ) -> String? {
        if let stall = shownStall(status, stall) {
            return stallText(stall, strings: strings)
        }
        if case .exited = status, hostLoss != nil, let cause,
           let detail = causeText(cause, strings: strings),
           let lost = text(for: status, hostLoss: hostLoss, strings: strings) {
            return "\(lost) · \(detail)"
        }
        switch status {
        case .connected:
            return nil
        case .restoring:
            return strings.text("terminal.link.restoring", defaultValue: "Restoring…")
        case .starting:
            return strings.text("terminal.link.starting", defaultValue: "Starting…")
        case .exited:
            switch hostLoss {
            case .hostEnded:
                return strings.text("terminal.link.lost.hostEnded", defaultValue: "Terminal lost: its host process ended")
            case .sessionShutdown:
                return strings.text("terminal.link.lost.sessionShutdown", defaultValue: "Terminal lost: the session shut down")
            case .hostMissing:
                return strings.text("terminal.link.lost.hostMissing", defaultValue: "Terminal lost: its host is gone")
            case .restartExhausted:
                return strings.text("terminal.link.lost.restartExhausted", defaultValue: "Terminal stopped: its host kept failing")
            case .restartFailed:
                return strings.text("terminal.link.lost.restartFailed", defaultValue: "Terminal stopped: it could not restart")
            case nil:
                return strings.text("terminal.link.exited", defaultValue: "Process exited")
            }
        case .disconnected(.turnedOffByOrganization, _):
            return strings.text("terminal.link.turnedOffByOrganization", defaultValue: "Turned off by your organization")
        case .disconnected(_, reconnecting: true):
            return strings.text("terminal.link.reconnecting", defaultValue: "Reconnecting…")
        case .disconnected(let cause, reconnecting: false):
            let reason = switch cause {
            case .streamEnded:
                strings.text("terminal.link.streamEnded", defaultValue: "Disconnected: the stream ended")
            case .connectionLost:
                strings.text("terminal.link.connectionLost", defaultValue: "Disconnected: connection lost")
            case .attachFailed:
                strings.text("terminal.link.attachFailed", defaultValue: "Disconnected: could not attach")
            case .turnedOffByOrganization:
                strings.text("terminal.link.turnedOffByOrganization", defaultValue: "Turned off by your organization")
            case .fellBehind:
                strings.text("terminal.link.fellBehind", defaultValue: "Disconnected: output fell behind")
            }
            let hint = strings.text("terminal.link.hint", defaultValue: "Click or type to reconnect")
            return "\(reason) · \(hint)"
        }
    }

    /// The stall the banner names: any, unless the terminal exited or an
    /// administrator turned the link off.
    private static func shownStall(_ status: TerminalConnectionStatus, _ stall: TerminalShellStall?) -> TerminalShellStall? {
        guard status != .exited, status != .disconnected(.turnedOffByOrganization, reconnecting: false) else { return nil }
        return stall
    }

    /// The label of a shell the daemon cannot reach.
    static func stallText(_ stall: TerminalShellStall, strings: ModuleResourceBundle) -> String {
        let close = strings.text("terminal.link.stall.closeHint", defaultValue: "Close the tab to end it")
        switch stall {
        case .reconnecting:
            return strings.text("terminal.link.stall.reconnecting", defaultValue: "Reconnecting to the shell…")
        case .linkLost:
            // The shell may still run and the daemon keeps retrying; the
            // Recover button above the label rehosts it at once.
            let reason = strings.text("terminal.link.stall.linkLostRetrying", defaultValue: "cmux lost its link to the shell")
            let retrying = strings.text("terminal.link.stall.retryingHint", defaultValue: "Still retrying")
            return "\(reason) · \(retrying)"
        case .otherBuild:
            let reason = strings.text("terminal.link.stall.otherBuild", defaultValue: "Terminal stopped: another cmux build owns its shell")
            return "\(reason) · \(close)"
        }
    }

    /// "SIGTERM from bash (pid 84954)", "the host had panicked", both, or
    /// nil when the host left no evidence.
    static func causeText(_ cause: TerminalHostLossCause, strings: ModuleResourceBundle) -> String? {
        var parts: [String] = []
        if let signal = cause.signal, let pid = cause.senderPid {
            if let sender = cause.senderName, !sender.isEmpty {
                parts.append(strings.text("terminal.link.lost.cause.signal",
                                          defaultValue: "\(signal) from \(sender) (pid \(pid))"))
            } else {
                parts.append(strings.text("terminal.link.lost.cause.signalFromPid",
                                          defaultValue: "\(signal) from pid \(pid)"))
            }
        }
        if cause.panicked {
            parts.append(strings.text("terminal.link.lost.cause.panicked", defaultValue: "the host had panicked"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
