public import AppKit
import CmuxNextDesign

/// The live view that pops up in the chat while the Chief is using its computer, over the transcript
/// at the top right, so no message moves. Status is read only during a Chief turn
/// (``follow(working:)``), and frames only while it shows. A click opens the Chief's page; the ✕
/// keeps it away for the rest of the turn.
@MainActor
public final class HomeChiefComputerPopup: NSView {
    static let width: CGFloat = 240
    static let inset: CGFloat = 8

    public let section = HomeChiefComputerSection()
    /// A click on the screen.
    public var onOpen: () -> Void = {}
    /// The chat already shows the computer beside it (its page is open): no popup.
    public var isSuppressed: () -> Bool = { false }
    /// Showing or hiding.
    public var onVisibility: () -> Void = {}

    private var working = false
    private var dismissed = false
    private(set) lazy var dismissButton = HomeChiefCardCloseButton(label: HomeEngineStrings.closeCard, target: self, action: #selector(dismiss), size: 22, symbolSize: 10)

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = HomeChiefComputerSection.screenCorner + Self.inset
        layer?.cornerCurve = .continuous
        shadow = NSShadow()
        layer?.shadowOpacity = 0.3
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -4)
        translatesAutoresizingMaskIntoConstraints = false
        section.translatesAutoresizingMaskIntoConstraints = false
        section.watchesScreen = false
        section.onStatus = { [weak self] in self?.update() }
        section.onResize = { [weak self] in self?.update() }
        addSubview(section)
        addSubview(dismissButton)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            section.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            section.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            section.topAnchor.constraint(equalTo: topAnchor, constant: Self.inset),
            section.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.inset),
            dismissButton.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            dismissButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(open)))
        setAccessibilityIdentifier("cmux.home.chief.computer.popup")
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// A Chief turn started or ended. A new turn clears the ✕.
    public func follow(working: Bool) {
        if working, !self.working { dismissed = false }
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

    func update() {
        let show = working && !dismissed && !isSuppressed() && section.shown?.acting == true
        section.watchesScreen = show
        guard show == isHidden else { return }
        isHidden = !show
        onVisibility()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        performWithTheme { layer?.backgroundColor = Palette.popupSurface.cgColor }
        if window != nil { follow(working: working) }
    }

    @objc private func open() { onOpen() }

    @objc private func dismiss() {
        dismissed = true
        update()
    }
}
