public import AppKit
public import CmuxNextCloud
import CmuxNextCompat
import CmuxNextDesign
public import CoreVideo

/// The Chief Settings card's Computer section (cmux issue 31488), in the place of Messages' Find
/// My on a contact: a "Computer" header, the Cloud machine's screen (16:10, view only), then its
/// name and state. While the machine runs, its screen streams for as long as the card is open;
/// paused, the screen says it is asleep. Hidden while ``HomeChiefComputer`` is nil (no paid plan,
/// or no machine has run).
@MainActor
public final class HomeChiefComputerSection: NSStackView {
    /// What the app gives the section; read only while the card is open.
    public struct Source {
        /// The account's Cloud machines (in the app's order) and whether the plan pays for Cloud,
        /// read under observation so the section follows a machine pausing or starting.
        public var directory: @MainActor @Sendable () -> (paid: Bool, machines: [CloudMachine])
        /// Starts machine `id`'s desktop frames, view only: `frame` gets each newest frame and
        /// `ended` runs once if the stream ends by itself. Returns how to stop it; nil when this
        /// Mac cannot reach the machine's desktop.
        public var frames: @MainActor (_ id: String, _ frame: @escaping @MainActor (CVPixelBuffer) -> Void,
                                       _ ended: @escaping @MainActor () -> Void) -> (@MainActor () -> Void)?

        public init(directory: @escaping @MainActor @Sendable () -> (paid: Bool, machines: [CloudMachine]),
                    frames: @escaping @MainActor (String, @escaping @MainActor (CVPixelBuffer) -> Void,
                                                  @escaping @MainActor () -> Void) -> (@MainActor () -> Void)?) {
            self.directory = directory
            self.frames = frames
        }
    }

    /// Set by the app; nil keeps the section hidden.
    public var source: Source? {
        didSet { if isOpen { open() } }
    }

    /// Runs when the section shows, hides or changes height (the card resizes).
    var onResize: () -> Void = {}

    /// What the section shows now; nil hides it.
    private(set) var shown: HomeChiefComputer?
    /// The machine whose screen streams now (nil: none), and how to stop it.
    private(set) var streaming: String?
    private var stopStream: (@MainActor () -> Void)?
    /// The stream of this machine ended by itself; it is not retried until its state changes.
    private var endedStream: String?
    private var isOpen = false
    private var watch: Task<Void, Never>?

    private let header = ThemedLabel(labelWithString: HomeEngineStrings.computerSection)
    let screen = NSView()
    private let message = ThemedLabel(labelWithString: "")
    private let symbol = ThemedImageView()
    private let name = ThemedLabel(labelWithString: "")
    private let state = ThemedLabel(labelWithString: "")

    public init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = Metrics.space2
        header.font = Typography.header
        header.ink = .secondary
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
        name.font = Typography.body
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        state.font = Typography.body
        state.ink = .secondary
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let row = NSStackView(views: [name, spacer, state])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Metrics.space2
        row.setAccessibilityElement(true)
        row.setAccessibilityIdentifier("cmux.home.chief.computer.state")
        // Says plainly that this is the Chief's own machine, which it uses for computer-use tasks (34263).
        let ownComputer = HomeChiefSettingsView.footnote(HomeEngineStrings.computerNote)
        ownComputer.preferredMaxLayoutWidth = HomeChiefSettingsView.width - 2 * HomeChiefSettingsView.inset
        ownComputer.setAccessibilityIdentifier("cmux.home.chief.computer.note")
        for view in [header, screen, row, ownComputer] as [NSView] {
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

    /// The card opened: follow the machines, and stream a running machine's screen.
    func open() {
        isOpen = true
        watch?.cancel()
        guard let source else { return show(nil) }
        let directory = source.directory
        // The first value applies now, so the card opens at its final height.
        let (first, later) = ObservationStream.current { () -> HomeChiefComputer? in
            let now = directory()
            return HomeChiefComputer(machines: now.machines, paid: now.paid)
        }
        show(first)
        // task-owner: the open card's machine watch; cancelled when the card closes
        watch = Task { [weak self] in
            for await computer in later { self?.show(computer) }
        }
    }

    /// The card closed: the stream stops, so this Mac stops reading the machine's desktop.
    func close() {
        isOpen = false
        watch?.cancel()
        watch = nil
        endedStream = nil
        stream(nil)
    }

    /// Shows `computer` (nil hides the section) and streams its screen while it runs.
    func show(_ computer: HomeChiefComputer?) {
        if computer?.machineID != shown?.machineID || computer?.state != .live { endedStream = nil }
        let resized = (computer == nil) != (shown == nil)
        shown = computer
        isHidden = computer == nil
        let live = computer.flatMap { $0.state == .live && endedStream != $0.machineID ? $0.machineID : nil }
        stream(isOpen ? live : nil)
        redraw()
        if resized { onResize() }
    }

    private func stream(_ machine: String?) {
        guard machine != streaming else { return }
        stopStream?()
        stopStream = nil
        streaming = nil
        screen.layer?.contents = nil
        guard let machine, let source else { return }
        streaming = machine
        stopStream = source.frames(machine, { [weak self] buffer in
            guard let self, streaming == machine else { return }
            let first = screen.layer?.contents == nil
            // The frame's IOSurface is never written again (CloudDesktopFrames), so the layer shows it as is.
            screen.layer?.contents = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue()
            // Only the first frame changes the labels (it takes "Connecting…" away).
            if first { redraw() }
        }, { [weak self] in
            guard let self, streaming == machine else { return }
            stopStream = nil
            streaming = nil
            endedStream = machine
            screen.layer?.contents = nil
            redraw()
        })
        if stopStream == nil {
            streaming = nil
            endedStream = machine
        }
    }

    private func redraw() {
        guard let shown else { return }
        name.stringValue = shown.name
        let note: (text: String, symbol: String?)?
        switch shown.state {
        case .live where streaming == shown.machineID:
            note = screen.layer?.contents == nil ? (HomeEngineStrings.computerConnecting, nil) : nil
        case .live, .unavailable: note = (HomeEngineStrings.computerUnavailable, nil)
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
        screen.setAccessibilityLabel(note?.text ?? HomeEngineStrings.computerScreen(shown.name))
    }
}
