public import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextWakeups

/// A live video of the computer (the Cloud desktop's stream), shown in place of the polled stills once it has a frame.
@MainActor
public protocol HomeChiefComputerLiveFeed: AnyObject {
    var view: NSView { get }
    /// Frames are showing now.
    var isLive: Bool { get }
    /// The stream's size in pixels.
    var pixels: CGSize { get }
    /// The agent's pointer in stream pixels; nil while no agent acts.
    var pointer: CGPoint? { get }
    /// Its session's state, for diagnostics.
    var debugStatus: String { get }
    /// Its state or pointer changed.
    var onChange: (() -> Void)? { get set }
    func stop()
}

/// The Chief profile card's Computer tab (cmux issue 31488): the Chief's own computer's screen
/// (16:10, view only) with "<name>'s screen" under it (Lawrence's reference, 2026-11-04). While the
/// computer runs and the tab shows, its screen refreshes, so the person watches the Chief work on
/// it; asleep, the screen says so and is not woken. Hidden while ``HomeChiefComputer`` is nil (no
/// paid plan, or the Chief has no computer now).
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
        /// Where the agent's pointer is in the last frame's pixels; nil while no agent is acting.
        public var pointer: @MainActor @Sendable () -> CGPoint?
        /// Starts a live video of the computer; nil when it has none.
        public var live: @MainActor @Sendable () -> (any HomeChiefComputerLiveFeed)?
        /// Paces the reads (a ``DemandTimer`` on it; tests pass a manual clock).
        public var clock: any Clock<Duration>

        public init(paid: @escaping @MainActor @Sendable () -> Bool, chief: @escaping @MainActor @Sendable () -> String,
                    status: @escaping @MainActor @Sendable () async -> HomeChiefComputer.Status?,
                    screen: @escaping @MainActor @Sendable () async -> CGImage?,
                    pointer: @escaping @MainActor @Sendable () -> CGPoint? = { nil },
                    live: @escaping @MainActor @Sendable () -> (any HomeChiefComputerLiveFeed)? = { nil },
                    clock: any Clock<Duration> = ContinuousClock()) {
            self.paid = paid
            self.chief = chief
            self.status = status
            self.screen = screen
            self.pointer = pointer
            self.live = live
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
        didSet {
            if !watchesScreen { endFeed() }
            if watchesScreen != oldValue, isOpen { open() }
        }
    }

    /// Expand, on the screen's corner: opens the computer large; nil hides it.
    public var onExpand: (() -> Void)? {
        didSet { expandButton.isHidden = onExpand == nil }
    }
    private(set) lazy var expandButton = HomeChiefCardCloseButton(label: HomeEngineStrings.computerExpand, target: self, action: #selector(expand),
                                                                  size: 26, symbolSize: 11, symbol: "arrow.up.left.and.arrow.down.right")

    /// Makes what draws the agent's cursor in a layer (the app's branded cursor: a screen capture has none);
    /// it takes a point in that layer, nil to take the cursor away.
    public var pointerPainter: ((CALayer) -> (CGPoint?) -> Void)?
    private var paintPointer: ((CGPoint?) -> Void)?
    /// Holds the cursor's layers over the frame; never takes a click.
    private let pointerPlane = HomeChiefComputerPointerPlane()
    /// Holds the live video over the last still, hidden until it has a frame.
    private let livePlane = HomeChiefComputerPointerPlane()
    private var feed: (any HomeChiefComputerLiveFeed)?

    /// Runs when the section shows or hides.
    public var onResize: () -> Void = {}
    /// Runs after each read is shown (the popup follows ``HomeChiefComputer/acting`` and its page opening).
    public var onStatus: () -> Void = {}

    /// What the section shows now; nil hides it.
    public private(set) var shown: HomeChiefComputer?
    /// The last status said the owner's plan pays for the Chief's computer (the Cloud service's own read,
    /// which holds while the app's plan read has not answered).
    public private(set) var entitled = false
    /// The last status said a computer the owner asked for is being made.
    public private(set) var provisioning = false
    /// The last status said the computer the owner asked for was not made.
    public private(set) var provisionFailed = false
    /// Frames shown since the card opened (tests).
    private(set) var frames = 0
    public private(set) var isOpen = false
    /// The read in flight (one status and, while it runs, one frame).
    private var watch: Task<Void, Never>?
    /// The next read, on the source's clock.
    private var next: DemandTimer?

    static let screenCorner: CGFloat = 14
    let screen = HomeChiefComputerScreenView()
    /// Light on the dark card in both themes.
    let message = NSTextField(labelWithString: "")
    let sleepFace = HomeChiefComputerSleepFace()
    let caption = ThemedLabel(labelWithString: "")

    public init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .centerX
        spacing = Metrics.space4
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
        message.textColor = NSColor(white: 0.86, alpha: 1)
        let note = NSStackView(views: [sleepFace, message])
        note.orientation = .vertical
        note.alignment = .centerX
        note.spacing = 6
        note.translatesAutoresizingMaskIntoConstraints = false
        screen.addSubview(note)
        expandButton.isHidden = true
        expandButton.setAccessibilityIdentifier("cmux.home.chief.computer.expand")
        livePlane.wantsLayer = true
        livePlane.isHidden = true
        livePlane.translatesAutoresizingMaskIntoConstraints = false
        screen.addSubview(livePlane)
        pointerPlane.wantsLayer = true
        pointerPlane.translatesAutoresizingMaskIntoConstraints = false
        screen.addSubview(pointerPlane)
        screen.addSubview(expandButton)
        for view in [screen, caption] as [NSView] {
            addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            screen.heightAnchor.constraint(equalTo: screen.widthAnchor, multiplier: 10.0 / 16.0),
            livePlane.leadingAnchor.constraint(equalTo: screen.leadingAnchor),
            livePlane.trailingAnchor.constraint(equalTo: screen.trailingAnchor),
            livePlane.topAnchor.constraint(equalTo: screen.topAnchor),
            livePlane.bottomAnchor.constraint(equalTo: screen.bottomAnchor),
            pointerPlane.leadingAnchor.constraint(equalTo: screen.leadingAnchor),
            pointerPlane.trailingAnchor.constraint(equalTo: screen.trailingAnchor),
            pointerPlane.topAnchor.constraint(equalTo: screen.topAnchor),
            pointerPlane.bottomAnchor.constraint(equalTo: screen.bottomAnchor),
            note.centerXAnchor.constraint(equalTo: screen.centerXAnchor),
            note.centerYAnchor.constraint(equalTo: screen.centerYAnchor),
            note.widthAnchor.constraint(lessThanOrEqualTo: screen.widthAnchor, constant: -2 * Metrics.space4),
            // Inset from the card's rounded corner, clear of its edge.
            expandButton.topAnchor.constraint(equalTo: screen.topAnchor, constant: Metrics.space4),
            expandButton.trailingAnchor.constraint(equalTo: screen.trailingAnchor, constant: -Metrics.space4),
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

    /// The owner asks again: the last failure no longer stands, whatever the next status read says.
    func forgetProvisionFailure() { provisionFailed = false }

    /// The card closed: the screen stops refreshing, so nothing reads the computer.
    public func close() {
        isOpen = false
        stop()
        endFeed()
        paintPointer?(nil)
        frames = 0
        screen.image = nil
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

    /// A running screen is black glass; with no frame, a dark card behind the note in both themes
    /// (Lawrence's reference, 2026-11-04: the Chief's screen is a dark card, waking or asleep).
    private func applyScreenFill() {
        screen.layer?.backgroundColor = (screen.image == nil ? Self.cardFill : NSColor.black).cgColor
    }

    static let cardFill = NSColor(white: 0.12, alpha: 1)

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
                if let status {
                    self.entitled = status.entitled ?? self.entitled
                    self.provisioning = status.provisioning
                    self.provisionFailed = status.provisionError != nil
                }
                self.show(self.section(for: status, source))
                since = .zero
                self.onStatus()
                guard !Task.isCancelled else { return }
            }
            guard let self else { return }
            var wait = Self.statusInterval
            if self.shown?.state == .live, self.watchesScreen {
                self.startFeed(source)
                if self.feed?.isLive == true {
                    // The stream shows it all; re-placing keeps the cursor up while the agent pauses.
                    self.drawPointer(self.feed?.pointer)
                } else {
                    let image = await source.screen()
                    guard self.isOpen, !Task.isCancelled else { return }
                    if self.shown?.state == .live, self.feed?.isLive != true {
                        self.frame(image)
                        self.drawPointer(source.pointer())
                    }
                }
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
        guard source.paid() || entitled else { return nil }
        guard let status else { return shown.map { HomeChiefComputer(machineID: $0.machineID, title: $0.title, state: .unavailable) } }
        return HomeChiefComputer(status: status, paid: true, chief: source.chief())
    }

    /// Shows `computer` (nil hides the section).
    func show(_ computer: HomeChiefComputer?) {
        let resized = (computer == nil) != isHidden
        if computer?.state != .live || computer?.machineID != shown?.machineID {
            screen.image = nil
            endFeed()
        }
        shown = computer
        isHidden = computer == nil
        redraw()
        if resized { onResize() }
    }

    /// One frame of the running computer (nil: none came; the last one stays).
    private func frame(_ image: CGImage?) {
        guard let image else { return }
        let first = screen.image == nil
        screen.image = image
        frames += 1
        // Only the first frame changes the labels (it takes "Connecting…" away).
        if first { redraw() }
    }

    /// The live video is what shows (diagnostics).
    var isStreaming: Bool { feed?.isLive == true }
    var feedStatus: String { feed?.debugStatus ?? "none" }

    private func startFeed(_ source: Source) {
        guard feed == nil, let made = source.live() else { return }
        feed = made
        made.view.translatesAutoresizingMaskIntoConstraints = false
        livePlane.addSubview(made.view)
        NSLayoutConstraint.activate([
            made.view.leadingAnchor.constraint(equalTo: livePlane.leadingAnchor),
            made.view.trailingAnchor.constraint(equalTo: livePlane.trailingAnchor),
            made.view.topAnchor.constraint(equalTo: livePlane.topAnchor),
            made.view.bottomAnchor.constraint(equalTo: livePlane.bottomAnchor),
        ])
        made.onChange = { [weak self] in self?.feedChanged() }
    }

    private func feedChanged() {
        guard let feed else { return }
        if livePlane.isHidden == feed.isLive {
            livePlane.isHidden = !feed.isLive
            redraw()
        }
        guard feed.isLive else { return }
        screen.liveSize = feed.pixels
        drawPointer(feed.pointer, in: feed.pixels)
    }

    private func endFeed() {
        guard let ended = feed else { return }
        feed = nil
        ended.onChange = nil
        ended.stop()
        ended.view.removeFromSuperview()
        livePlane.isHidden = true
        screen.liveSize = nil
    }

    /// The agent's cursor at `pixel` of the frame on show; nil takes it away.
    private func drawPointer(_ pixel: CGPoint?, in size: CGSize? = nil) {
        if paintPointer == nil, let layer = pointerPlane.layer { paintPointer = pointerPainter?(layer) }
        guard let pixel, let image = size ?? (feed?.isLive == true ? feed?.pixels : nil) ?? screen.imageSize else {
            paintPointer?(nil)
            return
        }
        paintPointer?(HomeChiefComputerScreenView.point(ofPixel: pixel, in: screen.bounds.size, image: image))
    }

    private func redraw() {
        applyScreenFill()
        guard let shown else { return }
        caption.stringValue = shown.title
        let note: String? = switch shown.state {
        case .live: screen.image == nil && feed?.isLive != true ? HomeEngineStrings.computerConnecting : nil
        case .unavailable: HomeEngineStrings.computerUnavailable
        case .asleep: HomeEngineStrings.computerAsleep
        case .waking: HomeEngineStrings.computerWaking
        }
        message.stringValue = note ?? ""
        message.isHidden = note == nil
        sleepFace.isHidden = shown.state != .asleep && shown.state != .waking
        sleepFace.awake = shown.state == .waking
        screen.setAccessibilityLabel(note ?? shown.title)
    }

    @objc private func expand() { onExpand?() }
}

/// The layer the agent's cursor is drawn in, y-down like the screen; clicks go through it.
private final class HomeChiefComputerPointerPlane: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
