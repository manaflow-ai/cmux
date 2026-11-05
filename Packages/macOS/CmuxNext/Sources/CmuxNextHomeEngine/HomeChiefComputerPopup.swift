public import AppKit
public import CmuxNextHome
import CmuxNextDesign

/// The live view that pops up in the chat while the Chief is using its computer, over the transcript
/// at the top right, so no message moves. Status is read only during a Chief turn
/// (``follow(working:)``), and frames only while it shows. A click opens the Chief's card (its Computer section); the ✕
/// keeps it away for the rest of the turn.
@MainActor
public final class HomeChiefComputerPopup: NSView {
    static let width: CGFloat = 240
    static let inset: CGFloat = 8

    public let section = HomeChiefComputerSection()
    /// A click on the screen.
    public var onOpen: () -> Void = {}
    /// The chat already shows the computer (the Chief's card is open): no popup.
    public var isSuppressed: () -> Bool = { false }
    /// Showing or hiding.
    public var onVisibility: () -> Void = {}

    private var working = false
    private var dismissed = false
    private(set) lazy var dismissButton = HomeChiefCardCloseButton(label: HomeEngineStrings.closeCard, target: self, action: #selector(dismiss), size: 22, symbolSize: 10)

    public override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        section.translatesAutoresizingMaskIntoConstraints = false
        section.watchesScreen = false
        section.onStatus = { [weak self] in self?.update() }
        section.onResize = { [weak self] in self?.update() }
        // The glass sits behind the screen; the screen's own height sizes the popup.
        let card = Glass.makeOverlayPanel(cornerRadius: HomeChiefComputerSection.screenCorner + Self.inset)
        addSubview(card)
        addSubview(section)
        addSubview(dismissButton)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            section.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            section.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            section.topAnchor.constraint(equalTo: topAnchor, constant: Self.inset),
            section.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.inset),
            dismissButton.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            dismissButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
        setAccessibilityIdentifier("cmux.home.chief.computer.popup")
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// A Chief turn started or ended. A new turn clears the ✕.
    public func follow(working: Bool) {
        if working, !self.working {
            dismissed = false
            // The last turn's status says nothing about this one: no popup until it is read.
            section.show(nil)
        }
        self.working = working
        if working, window != nil {
            if !section.isOpen { section.open() }
        } else if section.isOpen {
            section.close()
        }
        update()
    }

    /// The popup is showing (tests).
    public var isShowing: Bool { !isHidden }

    /// Shows or hides the popup for the last read (the app calls it when what suppresses it changes).
    public func update() {
        let show = working && !dismissed && !isSuppressed() && section.shown?.acting == true
        section.watchesScreen = show
        guard show == isHidden else { return }
        isHidden = !show
        onVisibility()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { follow(working: working) }
    }

    /// A click anywhere but the ✕, which takes its own (a recognizer here would take the ✕'s too).
    public override func mouseDown(with event: NSEvent) {}

    public override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onOpen()
        update()
    }

    @objc private func dismiss() {
        dismissed = true
        update()
    }
}

extension HomeChiefComputerPopup {
    /// Puts the Chief's computer in a chat (cmux issue 31488): `source` feeds both the Computer section of
    /// `settings`' card and this popup, which floats over `transcript`, stays away while the card shows
    /// the computer, comes back as soon as the card closes, and runs `open` (the card) on a click.
    public func install(in transcript: HomeNativeTranscriptView, settings: HomeChiefSettingsPopover,
                        source: HomeChiefComputerSection.Source, open: @escaping () -> Void) {
        settings.content.computer.source = source
        section.source = source
        isSuppressed = { [weak settings] in settings?.isShown == true }
        onOpen = open
        settings.onClose = { [weak self] in self?.update() }
        onVisibility = { [weak transcript] in transcript?.needsLayout = true }
        transcript.setFloatingAccessory(self)
    }
}
