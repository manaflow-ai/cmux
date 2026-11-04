public import AppKit
import CmuxNextCompat
import CmuxNextDesign

/// The Chief Settings card's Computer section (cmux issue 31488), in the place of Messages' Find
/// My on a contact: "<name>'s Computer", the Chief's own computer's screen (16:10, view only),
/// then its state. While the computer runs, its screen refreshes for as long as the card is open,
/// so the person watches the Chief work on it; asleep, the screen says so and is not woken.
/// Hidden while ``HomeChiefComputer`` is nil (no paid plan, or the Chief never set up a computer).
@MainActor
public final class HomeChiefComputerSection: NSStackView {
    /// What the app gives the section; read only while the card is open.
    public struct Source {
        /// Whether the plan pays for cmux Cloud.
        public var paid: @MainActor () -> Bool
        /// The Chief's name, for "<name>'s Computer".
        public var chief: @MainActor () -> String
        /// The computer's status (``HomeChiefComputerRoute/status()``); nil when not known.
        public var status: @MainActor () async -> HomeChiefComputer.Status?
        /// The screen now (``HomeChiefComputerRoute/screen()``); nil while it sleeps or is not reached.
        public var screen: @MainActor () async -> CGImage?
        /// Waits between two reads (the injected clock; tests resume it themselves).
        public var pause: @MainActor (Duration) async throws -> Void

        public init(paid: @escaping @MainActor () -> Bool, chief: @escaping @MainActor () -> String,
                    status: @escaping @MainActor () async -> HomeChiefComputer.Status?,
                    screen: @escaping @MainActor () async -> CGImage?,
                    pause: @escaping @MainActor (Duration) async throws -> Void = { try await ContinuousClock().sleep(for: $0) }) {
            self.paid = paid
            self.chief = chief
            self.status = status
            self.screen = screen
            self.pause = pause
        }

        /// The Chief's computer through its owner route.
        public init(paid: @escaping @MainActor () -> Bool, chief: @escaping @MainActor () -> String, route: HomeChiefComputerRoute) {
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
    private var watch: Task<Void, Never>?

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
        watch?.cancel()
        guard let source else { return show(nil) }
        // task-owner: the open card's computer watch; cancelled when the card closes
        watch = Task { [weak self] in
            await self?.follow(source)
        }
    }

    /// The card closed: the screen stops refreshing, so nothing reads the computer.
    func close() {
        isOpen = false
        watch?.cancel()
        watch = nil
        frames = 0
        screen.layer?.contents = nil
        redraw()
    }

    /// Reads the state every ``statusInterval`` and, while it runs, a frame every ``frameInterval``,
    /// until the card closes.
    private func follow(_ source: Source) async {
        var statusDue = true
        var sinceStatus: Duration = .zero
        while isOpen, !Task.isCancelled {
            if statusDue {
                let status = await source.status()
                guard isOpen, !Task.isCancelled else { return }
                show(HomeChiefComputer(status: status, paid: source.paid(), chief: source.chief()))
                statusDue = false
                sinceStatus = .zero
            }
            let wait: Duration
            if shown?.state == .live {
                let image = await source.screen()
                guard isOpen, !Task.isCancelled else { return }
                if shown?.state == .live { frame(image) }
                wait = Self.frameInterval
            } else {
                wait = Self.statusInterval
            }
            do { try await source.pause(wait) } catch { return }
            sinceStatus += wait
            if sinceStatus >= Self.statusInterval { statusDue = true }
        }
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
