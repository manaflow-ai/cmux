public import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextWakeups

/// The Chief profile card's Computer tab (cmux issue 31488): the Chief's own computer's screen
/// (16:10, view only) with "<name>'s screen" under it (Lawrence's reference, 2026-11-04). While the
/// computer runs and the tab shows, its screen refreshes, so the person watches the Chief work on
/// it; asleep, the screen says so and is not woken. Hidden while ``HomeChiefComputer`` is nil (no
/// paid plan, or the Chief never set up a computer), which also hides the tab.
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

    /// Whether the screen is on show (the Computer tab is selected). While false only the state is
    /// read, which is what says whether the tab exists at all; no frame is fetched for a hidden tab.
    public var watchesScreen = true {
        didSet { if watchesScreen != oldValue, isOpen { open() } }
    }

    /// Runs when the section shows or hides.
    public var onResize: () -> Void = {}
    /// Runs after each read is shown (the popup follows ``HomeChiefComputer/acting`` and its page opening).
    public var onStatus: () -> Void = {}

    /// What the section shows now; nil hides it.
    public private(set) var shown: HomeChiefComputer?
    /// Frames shown since the card opened (tests).
    private(set) var frames = 0
    public private(set) var isOpen = false
    /// The read in flight (one status and, while it runs, one frame).
    private var watch: Task<Void, Never>?
    /// The next read, on the source's clock.
    private var next: DemandTimer?

    static let screenCorner: CGFloat = 14
    let screen = NSView()
    private let message = ThemedLabel(labelWithString: "")
    private let sleepFace = HomeChiefComputerSleepFace()
    let caption = ThemedLabel(labelWithString: "")

    public init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .centerX
        spacing = 10
        caption.font = Typography.system(size: TypeScale.detail, weight: TypeScale.regular)
        caption.ink = .secondary
        caption.alignment = .center
        caption.lineBreakMode = .byTruncatingTail
        caption.setAccessibilityIdentifier("cmux.home.chief.computer")
        screen.wantsLayer = true
        screen.layer?.cornerRadius = Self.screenCorner
        screen.layer?.cornerCurve = .continuous
        screen.layer?.masksToBounds = true
        screen.layer?.contentsGravity = .resizeAspect
        screen.setAccessibilityElement(true)
        screen.setAccessibilityRole(.image)
        screen.setAccessibilityIdentifier("cmux.home.chief.computer.screen")
        screen.translatesAutoresizingMaskIntoConstraints = false
        message.font = Typography.system(size: TypeScale.field, weight: TypeScale.regular)
        message.alignment = .center
        let note = NSStackView(views: [sleepFace, message])
        note.orientation = .vertical
        note.alignment = .centerX
        note.spacing = 6
        note.translatesAutoresizingMaskIntoConstraints = false
        screen.addSubview(note)
        for view in [screen, caption] as [NSView] {
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
    public func open() {
        isOpen = true
        stop()
        guard let source else { return show(nil) }
        let timer = DemandTimer(owner: "home.chief.computer", clock: source.clock)
        next = timer
        read(source, timer, sinceStatus: nil)
    }

    /// The card closed: the screen stops refreshing, so nothing reads the computer.
    public func close() {
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
        applyScreenFill()
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyScreenFill()
    }

    /// A running screen is black glass; with no frame, the card's own fill behind the note.
    private func applyScreenFill() {
        performWithTheme {
            screen.layer?.backgroundColor = screen.layer?.contents == nil ? Palette.hoverFill.cgColor : NSColor.black.cgColor
        }
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
                self.onStatus()
                guard !Task.isCancelled else { return }
            }
            guard let self else { return }
            var wait = Self.statusInterval
            if self.shown?.state == .live, self.watchesScreen {
                let image = await source.screen()
                guard self.isOpen, !Task.isCancelled else { return }
                if self.shown?.state == .live { self.frame(image) }
                self.onStatus()
                guard !Task.isCancelled else { return }
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
        applyScreenFill()
        guard let shown else { return }
        caption.stringValue = shown.title
        let note: String? = switch shown.state {
        case .live: screen.layer?.contents == nil ? HomeEngineStrings.computerConnecting : nil
        case .unavailable: HomeEngineStrings.computerUnavailable
        case .asleep: HomeEngineStrings.computerAsleep
        case .waking: HomeEngineStrings.computerWaking
        }
        message.stringValue = note ?? ""
        message.isHidden = note == nil
        sleepFace.isHidden = shown.state != .asleep
        screen.setAccessibilityLabel(note ?? shown.title)
    }
}
