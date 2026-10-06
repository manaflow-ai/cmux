import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// What a remote-terminal tab shows while its terminal's session is not
/// attached (plans/cmux-next/data-model.md 1.4): the machine, its state,
/// Connect when the user can start it, and the last screen the home
/// session saved. Never drops the reference.
final class RemoteTerminalPlaceholderView: NSView {
    enum State: Equatable {
        /// The session is connecting (or its terminal is being attached).
        case reconnecting
        /// The session is known but not connected; Connect retries it.
        case offline
        /// This Mac never connected the session.
        case unknown
    }

    private let icon = NSImageView()
    private let status = NSTextField(labelWithString: "")
    private let connect = NSButton()
    private let snapshotView = NSTextView()
    private let scroll = NSScrollView()
    private(set) var state: State = .reconnecting
    private(set) var machine = ""
    var onConnect: (() -> Void)?

    /// The glyph drawn (tests).
    var glyph: NSImage? { icon.image }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        icon.image = NSImage.icon(.machineRemote, size: .iconRowSize(forLabelPointSize: NSFont.systemFontSize))
        status.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        status.lineBreakMode = .byTruncatingMiddle
        connect.title = RemoteStrings.placeholderConnect
        connect.bezelStyle = .rounded
        connect.controlSize = .small
        connect.target = self
        connect.action = #selector(connectPressed)
        snapshotView.isEditable = false
        snapshotView.isSelectable = true
        snapshotView.drawsBackground = false
        snapshotView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        snapshotView.textContainerInset = NSSize(width: 12, height: 8)
        scroll.documentView = snapshotView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        snapshotView.autoresizingMask = [.width]
        let header = NSStackView(views: [icon, status, connect])
        header.orientation = .horizontal
        header.spacing = 8
        header.alignment = .centerY
        for view in [header, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        applyColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }

    /// Colors resolve in this view's theme scope (its workspace's theme).
    private func applyColors() {
        performWithTheme {
            icon.contentTintColor = Palette.textTertiary
            status.textColor = Palette.textSecondary
            snapshotView.textColor = Palette.textTertiary
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(machine: String, state: State, snapshot: String?) {
        self.machine = machine
        self.state = state
        status.stringValue = switch state {
        case .reconnecting: RemoteStrings.placeholderReconnecting(machine)
        case .offline: RemoteStrings.placeholderOffline(machine)
        case .unknown: RemoteStrings.placeholderUnknown(machine)
        }
        connect.isHidden = state != .offline || onConnect == nil
        setSnapshot(snapshot)
        setAccessibilityLabel(status.stringValue)
    }

    func setSnapshot(_ snapshot: String?) {
        let text = snapshot.flatMap { $0.isEmpty ? nil : $0 } ?? RemoteStrings.placeholderNoSnapshot
        guard snapshotView.string != text else { return }
        snapshotView.string = text
        snapshotView.scrollToEndOfDocument(nil)
    }

    var snapshotText: String { snapshotView.string }
    var statusText: String { status.stringValue }

    @objc private func connectPressed() { onConnect?() }
}
