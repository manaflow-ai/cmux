public import AppKit
import CmuxNextDesign

/// Small label over a terminal whose link is down: the last screen stays
/// visible behind it. Hidden while connected. The theme's raised surface and
/// secondary text, no accent.
final class TerminalStatusBanner: NSView {
    private let label = ThemedLabel(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = Metrics.lineWidth(1)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.ink = .secondary
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
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
        performWithTheme {
            layer?.backgroundColor = Palette.elevatedBackground.cgColor
            layer?.borderColor = Palette.separator.cgColor
        }
    }

    /// Clicks go to the terminal below (a click there re-attaches).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ status: TerminalConnectionStatus, hostLoss: TerminalHostLoss? = nil,
              cause: TerminalHostLossCause? = nil, stall: TerminalShellStall? = nil) {
        guard let text = Self.text(for: status, hostLoss: hostLoss, cause: cause, stall: stall) else {
            endReveal()
            isHidden = true
            return
        }
        label.stringValue = text
        setAccessibilityLabel(text)
        if let delay = Self.revealDelay(for: status, stall: stall) { reveal(after: delay) } else { endReveal() }
        isHidden = false
    }

    /// "Restoring…" fades in only after `restoringRevealDelay`, so an attach
    /// that answers at once (the usual case) never flashes the label.
    static let restoringRevealDelay: CFTimeInterval = 0.5
    /// "Reconnecting…" and "Reconnecting to the shell…" fade in only after
    /// `reconnectingRevealDelay`: a version handoff marks every tab adopting
    /// while the new daemon takes its host back (a slow host costs up to 1 s
    /// of connect retries and 2 s of handshake, after up to 2 s waiting for
    /// the owner to say ready), and a dropped view re-attaches at once. Those
    /// clear within it and never show; one that lasts still shows, and the
    /// lasting "Disconnected" and stopped states show at once.
    static let reconnectingRevealDelay: CFTimeInterval = 5
    static let revealHoldKey = "terminalStatus.restoringHold"
    static let revealFadeKey = "terminalStatus.restoringReveal"
    /// When the hidden banner was first asked to show, and its wait.
    private var revealing: (start: CFTimeInterval, delay: CFTimeInterval)?

    /// How long the label for `status` (with the daemon's `stall`) waits
    /// before it fades in; nil shows it at once. Only transient states wait.
    static func revealDelay(for status: TerminalConnectionStatus, stall: TerminalShellStall?) -> CFTimeInterval? {
        if let stall = shownStall(status, stall) {
            return stall == .reconnecting ? reconnectingRevealDelay : nil
        }
        switch status {
        case .restoring: return restoringRevealDelay
        case .disconnected(.turnedOffByOrganization, _): return nil
        case .disconnected(_, reconnecting: true): return reconnectingRevealDelay
        case .connected, .disconnected, .exited: return nil
        }
    }

    /// A banner already on screen stays; a hidden one waits `delay` first. A
    /// change while it still waits keeps the longer wait from the same start,
    /// so "Restoring…" turning into a reconnecting stall does not show early.
    private func reveal(after delay: CFTimeInterval) {
        let now = CACurrentMediaTime()
        let start: CFTimeInterval
        if isHidden {
            start = now
        } else if let pending = revealing, now < pending.start + pending.delay, delay > pending.delay {
            start = pending.start
        } else {
            return
        }
        revealing = (start, delay)
        guard let layer else { return }
        layer.add(Motion.hold("opacity", at: 0), forKey: Self.revealHoldKey)
        layer.add(Motion.overlays.scheduledFade(.fadeIn, "opacity", from: 0, to: 1, after: start + delay - now, on: layer),
                  forKey: Self.revealFadeKey)
    }

    private func endReveal() {
        revealing = nil
        layer?.removeAnimation(forKey: Self.revealHoldKey)
        layer?.removeAnimation(forKey: Self.revealFadeKey)
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
