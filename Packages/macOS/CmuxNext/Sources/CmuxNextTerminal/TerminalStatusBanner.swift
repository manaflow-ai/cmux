public import AppKit
import CmuxNextDesign

/// Small label over a terminal whose link is down: the last screen stays
/// visible behind it. Hidden while connected. Subtle gray, no accent.
final class TerminalStatusBanner: NSView {
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.88).cgColor
        layer?.borderColor = NSColor(white: 1, alpha: 0.08).cgColor
        layer?.borderWidth = Metrics.lineWidth(1)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = NSColor(white: 0.85, alpha: 1)
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

    /// Clicks go to the terminal below (a click there re-attaches).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ status: TerminalConnectionStatus, hostLoss: TerminalHostLoss? = nil) {
        guard let text = Self.text(for: status, hostLoss: hostLoss) else {
            isHidden = true
            return
        }
        label.stringValue = text
        setAccessibilityLabel(text)
        isHidden = false
    }

    /// The banner text, or nil while connected. An exited terminal whose
    /// host was lost (`hostLoss`) says so. `strings` defaults to this
    /// module's table and falls back to English if the bundle is gone.
    static func text(
        for status: TerminalConnectionStatus,
        hostLoss: TerminalHostLoss? = nil,
        strings: ModuleResourceBundle = .terminal
    ) -> String? {
        switch status {
        case .connected:
            return nil
        case .exited:
            return strings.text("terminal.link.exited", defaultValue: "Process exited")
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
}
