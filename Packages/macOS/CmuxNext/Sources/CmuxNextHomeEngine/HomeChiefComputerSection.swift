public import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextWakeups

/// The Chief Settings card's Computer section (cmux issue 31488), in the place of Messages' Find
/// My on a contact: "<name>'s Computer", the Chief's own computer's screen (16:10, view only),
/// then its state. While the computer runs, its screen refreshes for as long as the card is open,
/// so the person watches the Chief work on it; asleep, the screen says so and is not woken.
/// Hidden while ``HomeChiefComputer`` is nil (no paid plan, or the Chief never set up a computer).
@MainActor
public final class HomeChiefComputerSection: NSStackView {
    /// What the app gives the section; read only while the card is open.
    public struct Source: Sendable {
        /// Whether the plan pays for cmux Cloud.
        public var paid: @MainActor @Sendable () -> Bool
        /// The Chief's name, for "<name>'s Computer".
        public var chief: @MainActor @Sendable () -> String
        /// The computer's status (``HomeChiefComputerRoute/status()``); nil when not known.
        public var status: @MainActor @Sendable () async -> HomeChiefComputer.Status?
        /// The screen now (``HomeChiefComputerRoute/screen()``); nil while it sleeps or is not reached.
        public var screen: @MainActor @Sendable () async -> CGImage?
        /// Paces the reads (a ``DemandTimer`` on it; tests pass a manual clock).
        public var clock: any Clock<Duration>

        public init(paid: @escaping @MainActor @Sendable () -> Bool, chief: @escaping @MainActor @Sendable () -> String,
                    status: @escaping @MainActor @Sendable () async -> HomeChiefComputer.Status?,
                    screen: @escaping @MainActor @Sendable () async -> CGImage?,
                    clock: any Clock<Duration> = ContinuousClock()) {
            self.paid = paid
            self.chief = chief
            self.status = status
            self.screen = screen
            self.clock = clock
        }

        /// The Chief's computer through its owner route.
        public init(paid: @escaping @MainActor @Sendable () -> Bool, chief: @escaping @MainActor @Sendable () -> String,
                    route: HomeChiefComputerRoute) {
            self.init(paid: paid, chief: chief, status: { await route.status() }, screen: { await route.screen() })
        }
    }

    /// A new frame about once a second while it runs (the Chief acts in steps of a second or more).
    static let frameInterval: Duration = .milliseconds(900)
    /// The state is read again this often while the card is open.
    static let statusInterval: Duration = .seconds(8)

    /// Set by the app; nil keeps the section hidden.
    public var source: Source? {
        didSet { if isOpen { open() } }
    }

    /// Runs when the section shows or hides (the card resizes).
    var onResize: () -> Void = {}

    /// What the section shows now; nil hides it.
    private(set) var shown: HomeChiefComputer?
    /// Frames shown since the card opened (tests).
    private(set) var frames = 0
    private var isOpen = false
    /// The read in flight (one status and, while it runs, one frame).
    private var watch: Task<Void, Never>?
    /// The next read, on the source's clock.
    private var next: DemandTimer?

    private let header = ThemedLabel(labelWithString: "")
    let screen = NSView()
    private let message = ThemedLabel(labelWithString: "")
    private let symbol = ThemedImageView()
    private let state = ThemedLabel(labelWithString: "")

    public init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = Metrics.space2
        header.font = Typography.header
        header.ink = .secondary
        header.lineBreakMode = .byTruncatingTail
        header.setAccessibilityRole(.staticText)
        header.setAccessibilityIdentifier("cmux.home.chief.computer")
        screen.wantsLayer = true
        screen.layer?.backgroundColor = NSColor.black.cgColor
        screen.layer?.cornerRadius = Metrics.densityPaneCornerRadius
        screen.layer?.cornerCurve = .continuous
        screen.layer?.masksToBounds = true
        screen.layer?.contentsGravity = .resizeAspect
        screen.setAccessibilityElement(true)
        screen.setAccessibilityRole(.image)
        screen.setAccessibilityIdentifier("cmux.home.chief.computer.screen")
        screen.translatesAutoresizingMaskIntoConstraints = false
        message.font = Typography.caption
        message.ink = .secondary
        message.alignment = .center
        symbol.symbolConfiguration = NSImage.SymbolConfiguration(textStyle: .title2)
        symbol.ink = .secondary
        let note = NSStackView(views: [symbol, message])
        note.orientation = .vertical
        note.alignment = .centerX
        note.spacing = Metrics.space1
        note.translatesAutoresizingMaskIntoConstraints = false
        screen.addSubview(note)
        // The screen's note is always light on its black glass, in either theme.
        screen.appearance = NSAppearance(named: .darkAqua)
        state.font = Typography.body
        state.ink = .secondary
        state.setAccessibilityIdentifier("cmux.home.chief.computer.state")
        for view in [header, screen, state] as [NSView] {
            addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            screen.heightAnchor.constraint(equalTo: screen.widthAnchor, multiplier: 10.0 / 16.0),
            note.centerXAnchor.constraint(equalTo: screen.centerXAnchor),
            note.centerYAnchor.constraint(equalTo: screen.centerYAnchor),
            note.widthAnchor.constraint(lessThanOrEqualTo: screen.widthAnchor, constant: -2 * Metrics.space4),
        ])
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The card opened: read the computer's state, and while it runs, its screen.
    func open() {
        isOpen = true
        stop()
        guard let source else { return show(nil) }
        let timer = DemandTimer(owner: "home.chief.computer", clock: source.clock)
        next = timer
        read(source, timer, sinceStatus: nil)
    }

    /// The card closed: the screen stops refreshing, so nothing reads the computer.
    func close() {
        isOpen = false
        stop()
        frames = 0
        screen.layer?.contents = nil
        redraw()
    }

    /// The window went away without the card closing: stop reading all the same.
    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, isOpen { close() }
    }

    private func stop() {
        watch?.cancel()
        watch = nil
        next?.cancel()
        next = nil
    }

    /// One read: the state when ``statusInterval`` has passed since the last (`sinceStatus` nil:
    /// now), then while it runs a frame; then the next read on `timer`, after ``frameInterval``
    /// while it runs and ``statusInterval`` otherwise. Stops when the card closes.
    private func read(_ source: Source, _ timer: DemandTimer, sinceStatus: Duration?) {
        // task-owner: one read of the open card's computer; cancelled by stop() when the card closes
        watch = Task { [weak self] in
            var since = sinceStatus ?? Self.statusInterval
            if since >= Self.statusInterval {
                let status = await source.status()
                guard let self, self.isOpen, !Task.isCancelled else { return }
                self.show(self.section(for: status, source))
                since = .zero
            }
            guard let self else { return }
            var wait = Self.statusInterval
            if self.shown?.state == .live {
                let image = await source.screen()
                guard self.isOpen, !Task.isCancelled else { return }
                if self.shown?.state == .live { self.frame(image) }
                wait = Self.frameInterval
            }
            let after = since + wait
            timer.schedule(after: wait) { @MainActor [weak self] in
                guard let self, self.isOpen, self.next === timer else { return }
                self.read(source, timer, sinceStatus: after)
            }
        }
    }

    /// The section for a status read. A read that failed (nil) keeps a shown section, as
    /// unavailable, instead of hiding it until the next read.
    private func section(for status: HomeChiefComputer.Status?, _ source: Source) -> HomeChiefComputer? {
        guard source.paid() else { return nil }
        guard let status else { return shown.map { HomeChiefComputer(machineID: $0.machineID, title: $0.title, state: .unavailable) } }
        return HomeChiefComputer(status: status, paid: true, chief: source.chief())
    }

    /// Shows `computer` (nil hides the section).
    func show(_ computer: HomeChiefComputer?) {
        let resized = (computer == nil) != isHidden
        if computer?.state != .live || computer?.machineID != shown?.machineID { screen.layer?.contents = nil }
        shown = computer
        isHidden = computer == nil
        redraw()
        if resized { onResize() }
    }

    /// One frame of the running computer (nil: none came; the last one stays).
    private func frame(_ image: CGImage?) {
        guard let image else { return }
        let first = screen.layer?.contents == nil
        screen.layer?.contents = image
        frames += 1
        // Only the first frame changes the labels (it takes "Connecting…" away).
        if first { redraw() }
    }

    private func redraw() {
        guard let shown else { return }
        header.stringValue = shown.title
        let note: (text: String, symbol: String?)?
        switch shown.state {
        case .live: note = screen.layer?.contents == nil ? (HomeEngineStrings.computerConnecting, nil) : nil
        case .unavailable: note = (HomeEngineStrings.computerUnavailable, nil)
        case .asleep: note = (HomeEngineStrings.computerAsleep, "moon.zzz.fill")
        case .waking: note = (HomeEngineStrings.computerWaking, nil)
        }
        state.stringValue = switch shown.state {
        case .live: HomeEngineStrings.computerStateLive
        case .asleep: HomeEngineStrings.computerStateAsleep
        case .waking: HomeEngineStrings.computerStateWaking
        case .unavailable: HomeEngineStrings.computerStateUnavailable
        }
        message.stringValue = note?.text ?? ""
        message.isHidden = note == nil
        symbol.image = note?.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        symbol.isHidden = symbol.image == nil
        screen.setAccessibilityLabel(note?.text ?? HomeEngineStrings.computerScreen(shown.title))
    }
}
