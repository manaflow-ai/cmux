public import AppKit
import CmuxNextDesign

/// The live view that pops up in the chat while the Chief is using its computer, over the transcript
/// at the top right, so no message moves. Status is read only during a Chief turn
/// (``follow(working:)``), and frames only while it shows. A click opens the Chief's profile at Computer; the ✕
/// keeps it away for the rest of the turn. Take Over under the screen hands it to the person right here: the
/// popup grows and its screen becomes the computer's mouse and keyboard until they give it back.
@MainActor
public final class HomeChiefComputerPopup: NSView {
    static let width: CGFloat = 320
    /// While the person drives: large enough to click in.
    static let drivingWidth: CGFloat = 560
    static let inset: CGFloat = 8

    public let section = HomeChiefComputerSection()
    let controlBar = HomeChiefComputerControlBar()
    /// The Chief's name, for the bar.
    public var chief: () -> String {
        get { controlBar.chief }
        set { controlBar.chief = newValue }
    }
    private let inputs = HomeChiefComputerInputQueue()
    private var controlKey: [String?]?
    private lazy var widthConstraint = widthAnchor.constraint(equalToConstant: Self.width)
    /// A click on the screen.
    public var onOpen: () -> Void = {}
    /// The chat already shows the computer (the profile at Computer, or the large page): no popup.
    public var isSuppressed: () -> Bool = { false }
    /// An agent is on the computer right now, whether or not a Chief turn runs: the preview follows the computer, not the turn.
    public var inUse: () -> Bool = { false }
    /// Showing or hiding.
    public var onVisibility: () -> Void = {}

    private var working = false
    private var dismissed = false
    private(set) lazy var dismissButton = HomeChiefCardCloseButton(label: HomeEngineStrings.closeCard, target: self, action: #selector(dismiss), size: 22, symbolSize: 10)

    public override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        section.watchesScreen = false
        section.onStatus = { [weak self] in self?.update() }
        section.onResize = { [weak self] in self?.update() }
        // The glass sits behind the screen; the screen's own height sizes the popup.
        let card = Glass.makeOverlayPanel(cornerRadius: HomeChiefComputerSection.screenCorner + Self.inset)
        addSubview(card)
        let content = NSStackView(views: [section, controlBar])
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = Metrics.space2
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        addSubview(dismissButton)
        controlBar.onChange = { [weak self] in self?.leaseChanged() }
        controlBar.beforeGiveBack = { [weak self] in
            let inFlight = self?.inputs.drop()
            await inFlight?.value
        }
        inputs.failed = { [weak self] in
            guard let self, controlBar.personDrives else { return }
            controlBar.sendFailed()
        }
        NSLayoutConstraint.activate([
            widthConstraint,
            section.widthAnchor.constraint(equalTo: content.widthAnchor),
            controlBar.widthAnchor.constraint(equalTo: content.widthAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            content.topAnchor.constraint(equalTo: topAnchor, constant: Self.inset),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.inset),
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
            if !inUse() { section.show(nil) }
        }
        self.working = working
        followOpen()
        update()
    }

    /// The computer the bar changes (see ``HomeChiefProfilePanel/follow(agent:machine:make:)``): a new source only when it changed.
    public func followControl(agent: String?, machine: String?, make: (String?, String?) -> HomeChiefComputerControlSource?) {
        let key = [agent, machine]
        guard key != controlKey else { return }
        let source = agent == nil && machine == nil ? nil : make(agent, machine)
        if source != nil || controlBar.source != nil { controlBar.source = source }
        controlKey = source == nil ? nil : key
    }

    /// Open while a turn runs, while an agent is on the computer, and while the person drives.
    private var active: Bool { working || inUse() || controlBar.personDrives }

    private func followOpen() {
        if active, window != nil {
            if !section.isOpen { section.open() }
        } else if section.isOpen {
            section.close()
        }
    }

    /// The lease changed, or an agent started on the computer: the status says so now, not at its next read.
    private func leaseChanged() {
        followOpen()
        if section.isOpen { section.open() }
        update()
    }

    /// The screen is the computer's mouse and keyboard only while it shows and the person drives.
    private func followInput() {
        let takes = !isHidden && controlBar.personDrives && !controlBar.givingBack && controlBar.source?.send != nil
        widthConstraint.constant = takes ? Self.drivingWidth : Self.width
        if takes {
            inputs.send = controlBar.source?.send
            inputs.resume()
            if section.screen.input == nil { section.screen.input = { [weak self] in self?.inputs.enqueue($0) } }
        } else {
            inputs.drop()
            if section.screen.input != nil { section.screen.input = nil }
        }
    }

    /// What decides the popup now, for `debug.home`.
    public var debugState: [String: String] {
        ["showing": "\(!isHidden)", "working": "\(working)", "in_use": "\(inUse())", "dismissed": "\(dismissed)", "suppressed": "\(isSuppressed())",
         "open": "\(section.isOpen)", "state": section.shown.map { "\($0.state)" } ?? "none", "acting": "\(section.shown?.acting ?? false)",
         "frames": "\(section.frames)", "live": "\(section.isStreaming)", "feed": section.feedStatus, "has_control": "\(controlBar.source != nil)", "person_drives": "\(controlBar.personDrives)",
         "in_window": "\(window != nil)", "frame": "\(frame)"]
    }

    /// The popup is showing (tests).
    public var isShowing: Bool { !isHidden }

    /// Shows or hides the popup for the turn, the ✕ and ``isSuppressed`` (a panel that closed brings it back).
    public func update() {
        followOpen()
        let wanted = controlBar.personDrives ? section.shown != nil : (working || inUse()) && section.shown?.acting == true
        let show = wanted && !dismissed && !isSuppressed()
        section.watchesScreen = show
        let before = widthConstraint.constant, changed = show == isHidden
        isHidden = !show
        followInput()
        if changed || widthConstraint.constant != before { onVisibility() }
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
