#if os(iOS)
import CmuxMobileArtifacts
import CmuxMobileDesign
import CmuxMobileSupport
import GhosttyNextKit
import SwiftUI
import UIKit
import OSLog

/// Why the PTY is resized and when the mirror is reset (DEBUG diagnosis of
/// resize/replay loops: `log stream --predicate 'category == "terminal-sizing"'`).
private let sizingLog = Logger(subsystem: "dev.cmux.mobile", category: "terminal-sizing")

/// Lays out the terminal screen in UIKit, where keyboard tracking is exact:
///
/// - The bottom stack (key row over the composer, classic cmux iOS's dock) is
///   pinned to the docked keyboard (`MobileKeyboardDock`, the keyboard layout
///   guide while it follows the keyboard), so it rides the keyboard's own
///   animation and interactive dismissal.
/// - Non-TUI: the Ghostty surface lives inside a `UIScrollView` whose content
///   height is the session's rows times the cell height. The surface is placed
///   at a row boundary in content coordinates and Ghostty's viewport is moved to
///   that row with a synchronous draw; the scroll view supplies the sub-row
///   pixel offset and its physics. Content runs under the toolbar and the
///   composer with the soft scroll edge effect.
/// - TUI (alternate screen): scrolling is off. The surface sits in a clip view
///   whose bottom is constrained to the composer's top and whose top is the
///   toolbar's bottom: the grid keeps its rows, follows the keyboard exactly and
///   is clipped at the top while the keyboard is up. Hard top edge.
///
/// Two chromes share this layout:
///
/// - `.standalone` (`TerminalScreen`): a navigation bar above, the safe area
///   below. The stack rests 8 pt above the home indicator.
/// - `.embedded` (a workspace tab inside CmuxTabsKit): TabsKit owns the
///   status bar and the floating toolbar; the controller is told how much of
///   the page they cover (`setEmbeddedInsets`). The stack then rests where
///   TabsKit puts a tab accessory (8 pt above the toolbar capsule) and rides
///   the keyboard from there. The stack stays in this controller (not in
///   TabsKit's SwiftUI accessory row) so the TUI clip, the scroll insets and
///   the stack are solved by one Auto Layout pass inside the keyboard's own
///   animation: the TUI frame cannot drift from the composer.
@MainActor
final class TerminalViewController: UIViewController, UIScrollViewDelegate {
    let model: TerminalModel
    let chrome: TerminalChrome
    let surface = TerminalSurfaceView(frame: .zero)
    /// Embedded: what TabsKit's status bar area (top) and toolbar (bottom,
    /// up to 8 pt above the capsule) cover.
    private var embeddedInsets = UIEdgeInsets.zero
    /// Stack bottom <= the chrome's resting line (safe area or toolbar).
    private var stackRestingLimit: NSLayoutConstraint!
    private var tuiTop: NSLayoutConstraint!
    /// Embedded: the status bar strip, registered as the top scroll edge container.
    private let topShelf = UIView()
    /// Embedded on iOS 26: the system draws no top scroll edge effect for a
    /// bare container (iOS 27 does), so a gradient fades the scrollback
    /// under the status bar instead.
    private let statusScrim = GradientView()
    private var statusScrimHeight: NSLayoutConstraint!

    private let scrollView = TerminalScrollView()
    private let tuiClip = UIView()
    private let tuiHost = UIView()
    private let bottomStack = UIView()
    private let bottomBacking = UIView()
    /// 24 pt fade above the composer card, shown only while rows are scrolled
    /// under it, so the row the card's edge cuts reads as "more below" (R2-6).
    private let bottomFade = GradientView()
    /// The last frame, held over the surface while a resize's mirror reset
    /// and replay are drawn, so the page never shows a black frame (R2-3).
    private var freezeView: UIView?
    private var freezeBatches = 0
    private var freezeStarted: CFTimeInterval = 0
    /// A reset's replay being fed: layout waits for all of it.
    private var replayGate = TerminalReplayGate()
    /// M-SIZELOG (G-07): when the last reset came and the bytes of its replay.
    private var replayStartedAt: CFTimeInterval?
    private var replayBytes = 0
    /// Holds the key row; Hide Toolbar folds it to 0 and hides it. The row
    /// keeps its 28 pt layout pinned to the top.
    private let keyBarClip = UIView()
    private let scrollToBottomButton = UIButton(configuration: .glass())
    private var scrollButtonVisibility = JumpToBottomVisibility()
    private var keyBarHost: UIHostingController<TerminalKeyBar>!
    private var composerHost: UIHostingController<TerminalComposer>!
    private var tuiHeight: NSLayoutConstraint!

    /// Rows of the local grid: the screen plus the largest keyboard, so the
    /// surface covers the old and new visible ranges during a keyboard animation.
    private var surfaceRows = 0
    /// Rows a TUI gets: between the toolbar and the composer, keyboard down.
    private var tuiRows = 0
    private var gridColumns = 0
    private var cell = CGSize.zero
    /// The Mac's grid when it is not the phone's (PROTOCOL.md "Terminal
    /// sizing policy"): the mirror takes its columns, the page pans sideways
    /// and a full-screen app is letterboxed or shifted (`TerminalHostGridLayout`).
    private var tuiPanX: CGFloat = 0
    private var tuiRowShift = 0
    /// The mirror width the last layout gave the surface, for `syncHostGrid`.
    private var mirrorWidth: CGFloat = 0
    /// "120×40 · set by Aziz's Mac" in a full-screen app's letterbox.
    private let hostGridNote = UILabel()
    private lazy var tuiHorizontalPan: UIPanGestureRecognizer = {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(tuiPanned(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        return pan
    }()
    private var tuiPanStartX: CGFloat = 0
    /// The Mac's columns as of the bytes fed so far (``TerminalSessionEvent/hostGrid(columns:rows:)``,
    /// taken in feed order); nil until the first, then the session's value.
    var appliedHostColumns: Int?
    /// The Mac's rows as of the same bytes (taken with the columns).
    var appliedHostRows: Int?
    /// The device that set the Mac's grid, when the size state names it
    /// (set by the size-state model; nil until then).
    var hostGridOwner: String? {
        didSet { if hostGridOwner != oldValue { applyTUIPlacement() } }
    }
    /// Ghostty's scrollbar: total rows, viewport top row, visible rows.
    private var scrollbar = (total: 0, offset: 0, visible: 0)
    /// The session's document: absolute rows from the first row with text
    /// (never the blank rows above the Mac's screen) to the cursor's row.
    private var document: TerminalDocumentLayout?
    /// Text selection over the rows (G-14).
    let selection = TerminalSelectionController()
    /// Selection in a full-screen app (vim, htop): a long press always selects,
    /// like Shift-drag on the Mac when the app captures the mouse (G-14).
    let tuiSelection = TerminalSelectionController()
    /// A vertical drag in a full-screen app scrolls the app (T-SCROLL-12).
    private let tuiScroll = TerminalTUIScrollController()
    /// A tap in a full-screen app: a click when the app asked for the mouse,
    /// and it focuses the terminal (not a tap that stops a fling).
    private lazy var tuiTap = UITapGestureRecognizer(target: self, action: #selector(tuiTapped(_:)))
    private var documentRows: Int { document?.rowCount ?? 0 }
    /// First absolute row of the document (content y 0).
    private var originRow: Int { document?.originRow ?? 0 }
    private var viewportTop = -1
    /// Ghostty's viewport for reading the cursor's row (termqa N3).
    private var viewportTracker = TerminalViewportTop()
    /// The viewport top row of the frame on screen.
    private var presentedTop = 0
    private var documentTotal = 0
    private var outputSinceProbe = false
    /// Row signatures of the frame on screen (the last one read).
    private var presentedRows: [UInt64]?
    /// The scrollback viewport a read frame confirmed: frames after it are
    /// placed without a pixel read until something moves the viewport.
    private var steadyViewport: TerminalSteadyViewport?
    /// Presents placed with and without a pixel read (the frame log reports them).
    private(set) var presentReads = 0
    private(set) var presentSkips = 0
    #if DEBUG
    var presentLog: [String] = []
    private var presentDebug = ""
    #endif
    /// Viewports requested before the current one (frames for them may still arrive).
    private var recentTops: [Int] = []
    /// The one owner of the scroll position (verify/terminal-scroll-model.md).
    private var scroll = TerminalScrollModel()
    private var following: Bool { scroll.isFollowing }
    /// Back from the alternate screen: until the user scrolls, Ghostty's
    /// latest viewport report places the surface. Frames on screen then
    /// have no earlier primary-screen frame to be matched against, and the
    /// first report after the switch can still describe the alternate screen.
    private var placesFromReport = false
    /// V5-1 rule switch for A/B on the rig (`-CmuxMobileNoJumpAwait` turns it off).
    private static let jumpAwaitsFrame = !CommandLine.arguments.contains("-CmuxMobileNoJumpAwait")
    private var refreshAfterTUI = false
    private(set) var started = false
    private var fling: FlingAnimator?
    /// What the dock shows (key row, composer) and the soft keyboard's state.
    private var dock = TerminalDockVisibility()
    private var tuiSizing = TerminalTUISizing()
    #if DEBUG
    /// DEBUG frame pacing while the page is dragged or decelerates: the gap
    /// between scroll callbacks (one per displayed frame while moving) and
    /// the main-thread time each callback took.
    struct ScrollMeter {
        var frames = 0, over17 = 0
        var longestMs = 0.0, longestStepMs = 0.0
        var last: CFTimeInterval = 0
        mutating func step(start: CFTimeInterval, end: CFTimeInterval, active: Bool) {
            guard active else { last = 0; return }
            if last > 0 {
                let gap = (start - last) * 1000
                frames += 1
                longestMs = max(longestMs, gap)
                if gap > 17.5 { over17 += 1 }
            }
            longestStepMs = max(longestStepMs, (end - start) * 1000)
            last = start
        }
    }
    private var scrollMeter = ScrollMeter()
    /// G-04: in-app frame intervals (`-CmuxMobileFrameLog`).
    private lazy var frameLog: TerminalFrameLog = {
        let log = TerminalFrameLog(surfaceName: model.title, frameDuration: 1.0 / Double(max(60, UIScreen.main.maximumFramesPerSecond)))
        log.phaseProvider = { [weak self] in
            guard let self else { return "gone" }
            switch self.scroll.state {
            case .following: return "following"
            case .reading: return "reading"
            case .interacting: return "interacting"
            }
        }
        log.blankProvider = { [weak self] in self?.legibleRowsBlank ?? false }
        return log
    }()

    /// `-CmuxMobileFrameLog`: the drawn cursor cell's and the document's last row's
    /// bottom edges against the composer card's top (page points) whenever
    /// they change while following. "drawn" is Ghostty's cursor cell in the
    /// presented surface, converted to the page (what the person sees); the
    /// document's row is the layout's own claim (round 11 N3: it said gap 0
    /// while the last row was under the card).
    private var lastPinLog = ""
    private func logPin() {
        guard TerminalFrameLog.isEnabled, following, let document, cell.height > 0 else { return }
        let lastRowBottom = document.contentY(ofRow: document.endRow, cellHeight: cell.height) - scrollView.contentOffset.y
        let composerTop = bottomStack.frame.minY
        // What is drawn: the cursor's cell in the frame on screen (termqa N3:
        // the document's end said gap 0 while the cursor row was drawn under
        // the card).
        let cursorBottom = surface.visibleCursorCell.map { surface.convert($0, to: view).maxY }
        let gap = TerminalDocumentLayout.drawnGap(composerTop: composerTop, lastRowBottom: lastRowBottom, cursorRowBottom: cursorBottom)
        let line = String(format: "pin: last row bottom %.1f, cursor row bottom %@, composer top %.1f, gap %.1f pt (keyboard %@, composer %.0f pt, rows %d)",
                          lastRowBottom, cursorBottom.map { String(format: "%.1f", $0) } ?? "-", composerTop, gap,
                          model.keyboardVisible ? "up" : "down", composerHost?.view.bounds.height ?? 0, document.rowCount)
        guard line != lastPinLog else { return }
        lastPinLog = line
        sizingLog.notice("\(line, privacy: .public)")
    }

    /// Times `body` as the screen's main-thread work in this frame and marks
    /// it with a signpost (G-04). DEBUG only; release builds call `body`.
    private func measured<T>(_ name: StaticString, _ body: () -> T) -> T {
        guard TerminalFrameLog.isEnabled else { return body() }
        let state = TerminalFrameLog.signposter.beginInterval(name)
        let start = CACurrentMediaTime()
        measureDepth += 1
        defer {
            measureDepth -= 1
            // Nested work is already inside the outer interval's time.
            frameLog.work("\(name)", CACurrentMediaTime() - start, outermost: measureDepth == 0)
            TerminalFrameLog.signposter.endInterval(name, state)
        }
        return body()
    }
    private var measureDepth = 0
    #else
    private func measured<T>(_ name: StaticString, _ body: () -> T) -> T { body() }
    #endif

    #if DEBUG
    /// Rig echo probe and text export (`-CmuxMobileTermProbe`, G-08/G-09).
    private lazy var devProbe: TerminalDevProbe? = TerminalDevProbe.isEnabled
        ? TerminalDevProbe(title: { [weak self] in self?.model.title ?? "" }, text: { [weak self] in self?.surface.screenRows()?.logicalText })
        : nil
    #endif

    /// The cursor's distance from the last row when it was last seen.
    private var cursorRowsFromEnd: Int?
    /// Keeps the end from moving up while a TUI redraws below the cursor (termqa D2).
    private var endHold = TerminalEndHold()

    /// The scroll model is setting the offset (not a person).
    private var settingOffset = false
    private var resizeSettle = TerminalResizeSettle()
    private var settleTask: Task<Void, Never>?
    /// Hide Toolbar: the key row's height is 0.
    private var keyRowCollapsed: NSLayoutConstraint!
    /// The composer is closed or hidden: its height is 0.
    private var composerCollapsed: NSLayoutConstraint!
    /// Counts dock reflows: only the last one's completion fades the key row in.
    private var dockReflow = 0
    /// The gap between the key row and the composer: 8 pt while both show,
    /// else 0. Always active (only its constant changes), so the stack's
    /// height stays fully determined.
    private var keyRowGap: NSLayoutConstraint!
    /// The stack's 8 pt bottom margin; 0 once Hide Toolbar folds everything.
    private var dockBottomMargin: NSLayoutConstraint!
    /// The docked keyboard's top edge, which the bottom stack rides.
    private var keyboardDock: MobileKeyboardDock!
    /// Keyboard notifications for `keyboardDock`; the controller lives as
    /// long as its tab, so it hears every one from its creation on.
    private let keyboardTracker = MobileKeyboardFrameTracker()
    /// A drag that began while following the prompt with the keyboard up:
    /// a downward drag dismisses the keyboard and the content stays pinned
    /// to the composer, row for row (SPEC M6).
    private var dragPin = KeyboardDragPin()
    private var dragPinsToComposer: Bool { dragPin.pinning }
    private var pinningDrag = false

    init(model: TerminalModel, chrome: TerminalChrome = .standalone) {
        self.model = model
        self.chrome = chrome
        super.init(nibName: nil, bundle: nil)
        model.controller = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        outputLink?.invalidate()
        followFallback?.invalidate()
        if outputPaused { model.session.setOutputPaused(false) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = CmuxMobileGhosttyApp.background
        // The terminal theme is dark: chrome, glass and the keyboard follow it.
        overrideUserInterfaceStyle = .dark
        view.clipsToBounds = true

        scrollView.delegate = self
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.keyboardDismissMode = .interactive
        scrollView.alwaysBounceVertical = true
        scrollView.indicatorStyle = .white
        scrollView.backgroundColor = .clear
        scrollView.topEdgeEffect.style = .soft
        scrollView.bottomEdgeEffect.style = .soft
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(surface)

        tuiClip.clipsToBounds = true
        tuiClip.isHidden = true
        tuiClip.translatesAutoresizingMaskIntoConstraints = false
        tuiHost.translatesAutoresizingMaskIntoConstraints = false
        tuiClip.addSubview(tuiHost)
        view.addSubview(tuiClip)
        tuiClip.addGestureRecognizer(tuiHorizontalPan)
        hostGridNote.font = UIFont.preferredFont(forTextStyle: .caption2)
        hostGridNote.textColor = .secondaryLabel
        hostGridNote.isHidden = true
        hostGridNote.isUserInteractionEnabled = false
        tuiHost.addSubview(hostGridNote)

        let keyBar = UIHostingController(rootView: TerminalKeyBar(model: model))
        let composer = UIHostingController(rootView: TerminalComposer(model: model))
        keyBar.safeAreaRegions = []
        composer.safeAreaRegions = []
        // The terminal is dark in both appearances; so are its key bar and
        // composer (in light mode inside a workspace they drew light glass
        // over the black grid).
        keyBar.overrideUserInterfaceStyle = .dark
        composer.overrideUserInterfaceStyle = .dark
        composer.sizingOptions = [.intrinsicContentSize]
        bottomStack.addSubview(keyBarClip)
        for host in [keyBar as UIViewController, composer] {
            host.view.backgroundColor = .clear
            host.view.translatesAutoresizingMaskIntoConstraints = false
            addChild(host)
            (host === keyBar ? keyBarClip : bottomStack).addSubview(host.view)
            host.didMove(toParent: self)
        }
        keyBarHost = keyBar
        composerHost = composer
        // Not clipped: the keys' glass lifts past the row on touch. Hide
        // Toolbar folds the row by hiding it, and unfolding fades it in
        // (`dockChanged`), so it never draws over the composer while it grows.
        keyBarClip.clipsToBounds = false
        // A rightward swipe on the key bar scrolls it or moves the joystick;
        // it never swipes back to the workspaces (R4-1).
        NavigationPopExclusion.shared.exclude(keyBarClip)
        keyBarClip.translatesAutoresizingMaskIntoConstraints = false
        bottomStack.translatesAutoresizingMaskIntoConstraints = false
        // The terminal background under the whole bottom chrome, from the
        // composer card's top to the page's bottom: rows scrolled under it are
        // not legible between and below the toolbar pills or at the
        // composer's corners (R1-2). Above the card the soft edge fades.
        bottomBacking.backgroundColor = CmuxMobileGhosttyApp.background
        bottomBacking.isUserInteractionEnabled = false
        bottomBacking.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottomBacking)
        let base = CmuxMobileGhosttyApp.background
        bottomFade.gradient.colors = [base.withAlphaComponent(0).cgColor, base.cgColor]
        bottomFade.isUserInteractionEnabled = false
        bottomFade.alpha = 0
        bottomFade.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottomFade)
        view.addSubview(bottomStack)
        // The bottom soft edge follows the composer like a system toolbar.
        let edge = UIScrollEdgeElementContainerInteraction()
        edge.scrollView = scrollView
        edge.edge = .bottom
        bottomStack.addInteraction(edge)

        // The joystick's thumb while dragged, above the key bar's clip.
        let thumb = UIHostingController(rootView: JoystickThumbOverlay(engine: model.joystickEngine))
        thumb.safeAreaRegions = []
        thumb.view.backgroundColor = .clear
        thumb.view.isUserInteractionEnabled = false
        thumb.view.translatesAutoresizingMaskIntoConstraints = false
        thumb.overrideUserInterfaceStyle = .dark
        addChild(thumb)
        view.addSubview(thumb.view)
        thumb.didMove(toParent: self)
        NSLayoutConstraint.activate([
            thumb.view.topAnchor.constraint(equalTo: view.topAnchor),
            thumb.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            thumb.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            thumb.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        scrollToBottomButton.configuration?.image = UIImage(systemName: "arrow.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        scrollToBottomButton.configuration?.cornerStyle = .capsule
        scrollToBottomButton.tintColor = .label
        scrollToBottomButton.accessibilityLabel = "Scroll to bottom"
        scrollToBottomButton.alpha = 0
        scrollToBottomButton.translatesAutoresizingMaskIntoConstraints = false
        scrollToBottomButton.addAction(UIAction { [weak self] _ in self?.scrollToBottom(animated: true) }, for: .primaryActionTriggered)
        // Jump to bottom is a row of the composer card now (Codex QA F3): a
        // button floating over the rows hid the end of the lines under it.
        scrollToBottomButton.isHidden = true
        view.addSubview(scrollToBottomButton)

        // Everything below derives from the keyboard layout guide alone, so
        // the keyboard's own animated layout pass moves the whole stack on the
        // keyboard's curve and timing. No constraint is changed from a
        // keyboard notification (that would commit on another timeline).
        //
        // guide.top is the keyboard's top, or the view's bottom when hidden.
        // Stack bottom = min(guide.top, safe area bottom) - 8. Inside the
        // stack, top to bottom (classic cmux iOS): the 28 pt key row, 8 pt,
        // the composer; Hide Toolbar folds both, closing the composer folds it.
        func prioritized(_ constraint: NSLayoutConstraint, _ priority: UILayoutPriority) -> NSLayoutConstraint {
            constraint.priority = priority
            return constraint
        }
        tuiHeight = tuiHost.heightAnchor.constraint(equalToConstant: 0)
        switch chrome {
        case .standalone:
            stackRestingLimit = bottomStack.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor)
            tuiTop = tuiClip.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)
        case .embedded:
            stackRestingLimit = bottomStack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor)
            tuiTop = tuiClip.topAnchor.constraint(equalTo: view.topAnchor)
            topShelf.isUserInteractionEnabled = false
            topShelf.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(topShelf)
            let topEdge = UIScrollEdgeElementContainerInteraction()
            topEdge.scrollView = scrollView
            topEdge.edge = .top
            topShelf.addInteraction(topEdge)
            if #unavailable(iOS 27) {
                statusScrim.isUserInteractionEnabled = false
                statusScrim.translatesAutoresizingMaskIntoConstraints = false
                let base = CmuxMobileGhosttyApp.background
                // A top bar under the status bar: solid terminal background
                // to the status bar's bottom, then a short fade. (A 92 %
                // gradient left scrollback legible under the clock; on iOS 26
                // the page read as having no top bar.)
                statusScrim.gradient.colors = [base.cgColor, base.cgColor, base.withAlphaComponent(0).cgColor]
                statusScrim.gradient.locations = [0, 0.75, 1]
                statusScrim.layer.zPosition = 1
                view.addSubview(statusScrim)
            }
        }
        // The stack rides the keyboard only while the keyboard is docked at
        // the bottom (`MobileKeyboardDock`). With a hardware keyboard the
        // system guide can report a 0-wide, 44 pt frame near the top (172 pt on
        // iPhone 17 Pro): pinned to it, the composer and key bar jumped to the
        // top of the page and the terminal went blank. On the iOS 27
        // simulator it can also stay at the bottom under a docked keyboard
        // (after a rotation the keyboard covered the dock). Away from the
        // bottom the stack rests at the chrome's line instead.
        keyboardDock = MobileKeyboardDock(view: view, usesBottomSafeArea: false, keyboard: keyboardTracker)
        keyboardDock.trackInteractiveDismissal(of: scrollView)
        let guide = keyboardDock.guide
        keyRowCollapsed = keyBarClip.heightAnchor.constraint(equalToConstant: 0)
        composerCollapsed = composer.view.heightAnchor.constraint(equalToConstant: 0)
        keyRowGap = composer.view.topAnchor.constraint(equalTo: keyBarClip.bottomAnchor, constant: TerminalDockMetrics.keyRowGap)
        dockBottomMargin = composer.view.bottomAnchor.constraint(equalTo: bottomStack.bottomAnchor, constant: -8)
        NSLayoutConstraint.activate([
            bottomStack.bottomAnchor.constraint(lessThanOrEqualTo: guide.topAnchor),
            prioritized(bottomStack.bottomAnchor.constraint(equalTo: guide.topAnchor), .defaultHigh),
        ])
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            bottomBacking.topAnchor.constraint(equalTo: bottomStack.topAnchor),
            bottomFade.bottomAnchor.constraint(equalTo: bottomStack.topAnchor),
            bottomFade.heightAnchor.constraint(equalToConstant: 24),
            bottomFade.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomFade.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBacking.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBacking.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBacking.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bottomStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stackRestingLimit,
            // Rest on the chrome's line when nothing pins the stack higher.
            prioritized(bottomStack.bottomAnchor.constraint(equalTo: view.bottomAnchor), .defaultLow),
            keyBarClip.topAnchor.constraint(equalTo: bottomStack.topAnchor),
            keyBarClip.leadingAnchor.constraint(equalTo: bottomStack.leadingAnchor),
            keyBarClip.trailingAnchor.constraint(equalTo: bottomStack.trailingAnchor),
            prioritized(keyBarClip.heightAnchor.constraint(equalToConstant: TerminalDockMetrics.keyRowHeight), .defaultHigh),
            keyBar.view.topAnchor.constraint(equalTo: keyBarClip.topAnchor),
            keyBar.view.leadingAnchor.constraint(equalTo: keyBarClip.leadingAnchor),
            keyBar.view.trailingAnchor.constraint(equalTo: keyBarClip.trailingAnchor),
            keyBar.view.heightAnchor.constraint(equalToConstant: TerminalDockMetrics.keyRowHeight),
            keyRowGap,
            composer.view.leadingAnchor.constraint(equalTo: bottomStack.leadingAnchor),
            composer.view.trailingAnchor.constraint(equalTo: bottomStack.trailingAnchor),
            dockBottomMargin,

            tuiTop,
            tuiClip.bottomAnchor.constraint(equalTo: bottomStack.topAnchor),
            tuiClip.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tuiClip.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tuiHost.bottomAnchor.constraint(equalTo: tuiClip.bottomAnchor),
            tuiHost.leadingAnchor.constraint(equalTo: tuiClip.leadingAnchor, constant: Self.sidePadding),
            tuiHost.trailingAnchor.constraint(equalTo: tuiClip.trailingAnchor, constant: -Self.sidePadding),
            tuiHeight,

            scrollToBottomButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            scrollToBottomButton.bottomAnchor.constraint(equalTo: bottomStack.topAnchor, constant: -10),
            scrollToBottomButton.widthAnchor.constraint(equalToConstant: 40),
            scrollToBottomButton.heightAnchor.constraint(equalToConstant: 40),
        ])
        if chrome == .embedded {
            NSLayoutConstraint.activate([
                topShelf.topAnchor.constraint(equalTo: view.topAnchor),
                topShelf.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                topShelf.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                topShelf.bottomAnchor.constraint(equalTo: tuiClip.topAnchor),
            ])
            if statusScrim.superview != nil {
                statusScrimHeight = statusScrim.heightAnchor.constraint(equalToConstant: 0)
                NSLayoutConstraint.activate([
                    statusScrim.topAnchor.constraint(equalTo: view.topAnchor),
                    statusScrim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                    statusScrim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                    statusScrimHeight,
                ])
            }
        }

        let tap = UITapGestureRecognizer(target: self, action: #selector(terminalTapped))
        scrollView.addGestureRecognizer(tap)
        tuiClip.addGestureRecognizer(tuiTap)
        // The model may already have a closed or hidden composer (a page rebuilt for it).
        dockChanged()
        installSelection()
        installTUIScroll()

        surface.configurePasteControlTarget()
        surface.onInput = { [weak self] data in
            #if DEBUG
            self?.devProbe?.sent(data)
            #endif
            self?.model.session.send(data)
        }
        // Every input path (keyboard, key bar, composer, paste) goes through
        // the surface's `perform`: typing brings the prompt into view, like Terminal.
        surface.onUserInput = { [weak self] in
            guard let self else { return }
            // Keys, pastes and the composer can use up or reset a sticky
            // modifier: the key row shows what is left.
            if self.model.sticky != self.surface.input.sticky { self.model.sticky = self.surface.input.sticky }
            self.revealCursorForInput()
        }
        surface.onEvent = { [weak self] event in self?.surfaceEvent(event) }
        surface.onPresent = { [weak self] in
            guard let self else { return }
            self.measured("present") { self.surfacePresented() }
        }
        surface.onFocusChange = { [weak self] focused in
            guard let self else { return }
            self.model.surfaceFocused = focused
            // Redraw at once: a focus change can come with a new composer
            // height and the frame must follow it (Codex QA F4).
            self.surface.drawNow()
            self.inputFocusChanged()
            // Direct typing stays the keyboard target in TUI mode after the keyboard hides.
            self.model.directTyping = focused || self.model.isTUI
        }
        surface.onStickyChange = { [weak self] sticky in self?.model.sticky = sticky }

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(keyboardWillShow(_:)), name: UIResponder.keyboardWillShowNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardWillHide(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardDidChange), name: UIResponder.keyboardDidShowNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardDidHide), name: UIResponder.keyboardDidHideNotification, object: nil)
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        registerEdgeEffectScrollView()
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        registerEdgeEffectScrollView()
        #if DEBUG
        frameLog.start()
        #endif
        startBlankWatch()
        // Back on screen (a tab switch, the grid): output that arrived while
        // the page was away was laid out against stale geometry. Recompute
        // the document and, when following, rest the last row above the
        // composer on the first frame (Codex QA F8).
        view.setNeedsLayout()
        view.layoutIfNeeded()
        outputSinceProbe = true
        updateDocument()
        applyScroll()
    }

    /// The only place the content offset is set (besides UIKit's own drags,
    /// decelerations and the keyboard-drag pin): the scroll model's target
    /// for the document and insets as they are now. Called after layout and
    /// after each processed output batch, so at most once per display frame.
    private func applyScroll(fromOutput: Bool = false) {
        // A deceleration stopped by a touch that never became a drag ends no
        // gesture: settle it here.
        if scroll.isInteracting, !scrollView.isTracking, !scrollView.isDragging, !scrollView.isDecelerating,
           fling == nil, !dragPinsToComposer, !model.isTUI, cell.height > 0 {
            scroll.settled(offsetY: scrollView.contentOffset.y, bottomOffsetY: maxOffsetY, layout: document, rowHeight: cell.height)
            #if DEBUG
            sizingLog.notice("scroll: settled by applyScroll -> \(String(describing: self.scroll.state), privacy: .public)")
            #endif
        }
        // UIKit is moving the page: leave it alone.
        if scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating, !dragPinsToComposer { return }
        guard !model.isTUI, cell.height > 0,
              let target = scroll.target(layout: document, rowHeight: cell.height, topInset: scrollView.contentInset.top,
                                         bottomOffsetY: maxOffsetY) else { return }
        // Following new output: the page moves when Ghostty's frame with the
        // new rows is presented (surfacePresented), in the same transaction.
        // Moved earlier, the old frame showed shifted up for one frame
        // (termqa round 2: a one-frame jump of 2 rows while Codex streamed).
        if fromOutput, scroll.isFollowing, target > scrollView.contentOffset.y + 0.5,
           presentedTop != scrollbar.offset, freezeView == nil {
            awaitFrame(ticks: 2)
            updateViewport(visibleMinY: scrollView.contentOffset.y)
            return
        }
        // A move whose rows the frame on screen does not all show (Jump to
        // bottom, a restore, a prune's renumbering) keeps the last good frame
        // and waits for the frame that does; moved at once, the page was
        // black for a frame (V5-1; V8 claim 1a: also a target partly in the
        // frame, and the fallback's forced move under fast output).
        if Self.jumpAwaitsFrame, !forceScroll, freezeView == nil, abs(scrollView.contentOffset.y - target) > 0.5,
           !targetCovered(target) {
            // The frame just placed is the only one there is: when it no
            // longer covers the page (it replaced the reader's frame), the
            // page shows its rows nearest the target meanwhile (qa11
            // wt-fling-b: the page waited at the reader's rows, black).
            if let document, let y = TerminalScrollGate.interimOffset(
                frame: surface.frame.minY..<surface.frame.maxY, document: 0..<document.contentHeight(cellHeight: cell.height),
                current: scrollView.contentOffset.y, target: target, viewport: view.bounds.height),
               abs(y - scrollView.contentOffset.y) > 0.5 {
                settingOffset = true
                scrollView.contentOffset.y = y
                settingOffset = false
                updateBottomFade()
            }
            awaitFrame(ticks: 6)
            updateViewport(visibleMinY: target)
            return
        }
        forceScroll = false
        followAwaitsPresent = false
        awaitStarted = nil
        if abs(scrollView.contentOffset.y - target) > 0.5 {
            settingOffset = true
            scrollView.contentOffset.y = target
            settingOffset = false
        }
        updateViewport(visibleMinY: scrollView.contentOffset.y)
        updateBottomFade()
        #if DEBUG
        logPin()
        #endif
        setScrollButton(visible: scrollButtonVisibility.update(
            offsetY: scrollView.contentOffset.y, minOffsetY: -scrollView.contentInset.top, maxOffsetY: maxOffsetY))
    }

    /// The navigation bar reads its scroll edge effect from the top view
    /// controller's content scroll view; SwiftUI's hosting controller is that
    /// controller, so it is told about this scroll view.
    private func registerEdgeEffectScrollView() {
        // Embedded: TabsKit's page is not a navigation controller's content;
        // the edge containers above are registered on the scroll view directly.
        guard chrome == .standalone else { return }
        var candidate: UIViewController? = self
        while let current = candidate {
            current.setContentScrollView(scrollView, for: .top)
            current.setContentScrollView(scrollView, for: .bottom)
            if current.parent is UINavigationController { break }
            candidate = current.parent
        }
    }

    /// Embedded: the chrome over the page changed (rotation, first layout).
    func setEmbeddedInsets(_ insets: UIEdgeInsets) {
        guard chrome == .embedded, insets != embeddedInsets else { return }
        embeddedInsets = insets
        tuiTop.constant = insets.top
        // Solid under the status bar, then an 18 pt fade that ends at the top
        // inset: row 0 at rest is at full brightness, and only rows scrolled
        // up under the status bar fade (R1-5).
        statusScrimHeight?.constant = insets.top
        if insets.top > 18 { statusScrim.gradient.locations = [0, NSNumber(value: Double((insets.top - 18) / insets.top)), 1] }
        // The composer rests 8 pt above the toolbar capsule, like a tab
        // accessory; the 8 pt below the (hidden) key bar are inside the stack.
        stackRestingLimit.constant = -(insets.bottom - 8)
        view.setNeedsLayout()
    }

    /// Top of the content area (under the navigation bar or the status bar).
    private var chromeTop: CGFloat {
        chrome == .embedded ? embeddedInsets.top : view.safeAreaInsets.top
    }

    /// A size the layout measured goes to the Mac only once it held for a
    /// moment (`TerminalResizeSettle`): each resize resets the mirror, and an
    /// inline TUI redraws its transcript.
    private func measuredGrid(columns: Int, rows: Int) {
        // Before the attach too: the size the session keeps goes out with the
        // attach, so a transient one (the grid's zoom animation measured 44
        // and 43 rows for a 42-row page) is held like any other. Sent at once,
        // the attach carried it and the settled size followed: two resets
        // and replays for one tab open (termqa D9).
        switch resizeSettle.measured(.init(columns: columns, rows: rows)) {
        case .sendNow(let size):
            sendResize(size, why: "first")
        case .wait:
            settleTask?.cancel()
            settleTask = Task { @MainActor [weak self] in
                try? await ContinuousClock().sleep(for: TerminalResizeSettle.settle)
                guard let self, !Task.isCancelled, let size = self.resizeSettle.settled() else { return }
                self.sendResize(size, why: "settled")
            }
        case .nothing:
            if resizeSettle.pending == nil { settleTask?.cancel() }
        }
    }

    private func sendResize(_ size: TerminalResizeSettle.Size, why: String) {
        sizingLog.notice("resize \(size.columns, privacy: .public)x\(size.rows, privacy: .public) cause=\(why, privacy: .public)\(self.model.isTUI ? "-tui" : "", privacy: .public) attached=\(self.model.connectionState.isAttached, privacy: .public) (TUI \(self.model.isTUI, privacy: .public))")
        model.session.resize(columns: size.columns, rows: size.rows)
    }

    /// The stack's top with the keyboard down and the composer at its one-line
    /// height: the rows never follow the composer's transient rows (Jump to
    /// bottom, attachments, a long draft).
    private var restingStackTop: CGFloat {
        restingComposerBottom - TerminalDockMetrics().restingStackHeight(lineHeight: bodyLineHeight, visibility: dock)
    }

    private var restingComposerHeight: CGFloat {
        dock.showsComposer ? TerminalDockMetrics().restingComposerHeight(lineHeight: bodyLineHeight) : 0
    }

    private var bodyLineHeight: CGFloat { UIFont.preferredFont(forTextStyle: .body).lineHeight }

    /// How much taller the composer card is now than at rest.
    /// The composer card's SwiftUI height changed (V6-1): the hosting view's
    /// size is measured again, and the page's insets follow in this pass.
    func composerCardHeightChanged(_ height: CGFloat) {
        guard let host = composerHost else { return }
        host.view.invalidateIntrinsicContentSize()
        host.view.setNeedsLayout()
        view.setNeedsLayout()
        view.layoutIfNeeded()
        applyScroll()
    }

    private var composerGrowth: CGFloat {
        dock.showsComposer ? max(0, composerHost.view.bounds.height - restingComposerHeight) : 0
    }

    /// The stack's last row's bottom (the composer's, or the key row's while
    /// it is closed) with the keyboard down.
    private var restingComposerBottom: CGFloat {
        switch chrome {
        case .standalone: view.bounds.height - view.safeAreaInsets.bottom - 8
        case .embedded: view.bounds.height - embeddedInsets.bottom
        }
    }

    /// A still of the page for the tab grid (the render server's copy of
    /// what is on screen, so the Metal surface is included). Cheap: no
    /// second Ghostty surface; taken when the grid opens or the page leaves.
    func snapshot(hidingCursor: Bool = false) -> UIImage? {
        capture(hidingCursor: hidingCursor)?.render()
    }

    /// The frame for the next cold launch, taken on the main thread and
    /// rendered off it (V8 claim 7: the render on the main thread was a
    /// 150-214 ms frame every ~15 s while output streamed). What the main
    /// thread still spends is the frame log's work (`frame-save`).
    func captureForSaving() -> TerminalPageCapture? {
        measured("frame-save") { capture(hidingCursor: true) }
    }

    /// What a still needs from the main thread: the presented frame's rows
    /// on the page (below the top inset, above the composer card) copied out
    /// of Ghostty's surface (`TerminalPageCapture.render` composes them on
    /// any thread). The page's chrome is not part of a still
    /// (`TerminalStillPlan`; qa11: the composer drawn across a card's middle).
    func capture(hidingCursor: Bool) -> TerminalPageCapture? {
        guard view.window != nil, view.bounds.width > 0 else { return nil }
        // The frame kept for a cold launch has no cursor: it is not where
        // typing goes until the live screen is back (R3-4). The glyph under
        // it stays (V8 claim 8).
        let cursor = hidingCursor ? surface.visibleCursorCell.map { surface.convert($0, to: view) } : nil
        let host: UIView = model.isTUI ? tuiClip : scrollView
        let rows = TerminalStillPlan.rowsClip(bounds: view.bounds, topInset: model.isTUI ? tuiClip.frame.minY : scrollView.contentInset.top,
                                              composerTop: bottomStack.frame.minY)
            .intersection(host.convert(host.bounds, to: view))
        var capture = TerminalPageCapture(bounds: view.bounds, scale: Self.snapshotScale, surface: nil, fallback: nil,
                                          surfaceClip: rows.isNull ? .zero : rows, surfaceFrame: .null, cursor: cursor,
                                          background: CmuxMobileGhosttyApp.background)
        guard !rows.isNull, !rows.isEmpty, surface.isDescendant(of: host) else { return capture }
        let clip = view.convert(rows, to: surface)
        if let copy = surface.presentedCopy(clip: clip) {
            // The surface drawn from the frame Ghostty presented: the render
            // server's copy of a live Metal surface came out black on the rig (V5-6).
            capture.surface = copy
            capture.surfaceFrame = surface.convert(copy.frame, to: view)
        } else if let presented = surface.presentedImage(clip: clip) {
            // The copy failed (an unexpected surface format): the frame
            // rendered here, on the main thread, as before the copy.
            sizingLog.notice("still: presented copy failed, rendered on the main thread")
            capture.fallback = presented.image
            capture.surfaceFrame = surface.convert(presented.frame, to: view)
        } else {
            sizingLog.notice("still: no presented frame; background only")
        }
        return capture
    }

    private static let snapshotScale: CGFloat = 2

    // MARK: Files and links (embedded)

    private weak var artifactsHost: UIViewController?

    func presentArtifacts() {
        guard artifactsHost == nil, presentedViewController == nil else { return }
        let model = model
        let host = UIHostingController(rootView: ArtifactsSheet(model: model).onDisappear { model.showArtifacts = false })
        host.overrideUserInterfaceStyle = .unspecified
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        artifactsHost = host
        present(host, animated: true)
    }

    /// A composer attachment's full-screen preview (UIKit, as Files and Artifacts is).
    func presentFilePreview(_ request: FilePreviewRequest) {
        guard presentedViewController == nil else { return }
        request.present(from: self)
    }

    func dismissArtifacts() {
        guard let host = artifactsHost, host.presentingViewController != nil, !host.isBeingDismissed else { return }
        host.dismiss(animated: true)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        #if DEBUG
        frameLog.stop()
        #endif
        stopBlankWatch()
        stopFollowFallback()
        if chrome == .embedded, let image = snapshot() { model.snapshot = image }
    }

    /// The terminal or the composer gained or lost focus.
    func inputFocusChanged() {
        // The key row shows with or without focus (classic); nothing to fold.
    }

    /// The model's composer or Hide Toolbar state changed: fold or unfold the
    /// key row and the composer, reflowed over 0.25 s (classic's dock).
    func dockChanged() {
        dock.chromeHidden = model.chromeHidden
        dock.composerPresented = model.composerPresented
        guard keyRowCollapsed != nil else { return }
        keyRowCollapsed.isActive = !dock.showsKeyRow
        composerCollapsed.isActive = !dock.showsComposer
        keyRowGap.constant = dock.showsKeyRow && dock.showsComposer ? TerminalDockMetrics.keyRowGap : 0
        dockBottomMargin.constant = dock.showsKeyRow || dock.showsComposer ? -8 : 0
        let revealsKeyRow = keyBarClip.isHidden && dock.showsKeyRow
        keyBarClip.isHidden = !dock.showsKeyRow
        // Unfolding: the row fades in once its slot is open, never over the composer.
        if revealsKeyRow { keyBarClip.alpha = 0 }
        composerHost.view.isHidden = !dock.showsComposer
        bottomBacking.isHidden = !dock.showsKeyRow && !dock.showsComposer
        view.setNeedsLayout()
        // motion: allow UIKit dock reflow, one bounded 0.25 s pass like classic's band; Reduce Motion applies it at once.
        let animate = view.window != nil && !UIAccessibility.isReduceMotionEnabled
        if animate {
            dockReflow += 1
            let reflow = dockReflow
            UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]) {
                self.view.layoutIfNeeded()
            } completion: { _ in
                // A newer reflow is still moving the slot: its completion fades the row in.
                if reflow == self.dockReflow {
                    // motion: allow the same gate as the reflow above (Reduce Motion skips it).
                    UIView.animate(withDuration: 0.15) { self.keyBarClip.alpha = 1 }
                }
                self.keyboardDidChange()
            }
        } else {
            view.layoutIfNeeded()
            keyBarClip.alpha = 1
            keyboardDidChange()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        keyboardDock.refresh()
        layoutTerminal()
        if !started, surface.surface != nil, cell.height > 0 {
            started = true
            model.session.start { [weak self] event in self?.sessionEvent(event) }
        }
    }

    #if DEBUG
    /// DEBUG (termqa round 8): what each Ghostty point tag reads for a few rows.
    var debugRowProbe: String {
        func short(_ text: String?) -> String {
            guard let text else { return "nil" }
            let line = text.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
            return "\"" + String(line.prefix(24)) + "\""
        }
        let rows = surface.grid.rows
        let total = scrollbar.total
        var parts = ["sb=\(total)/\(scrollbar.offset)/\(scrollbar.visible) grid.rows=\(rows) pinned=\(viewportTop) doc=\(originRow)+\(documentRows)"]
        for y in [0, 1, rows - 1, rows, rows + 1, total - rows, total - 1] where y >= 0 {
            parts.append("screen[\(y)]=" + short(surface.debugReadRow(tag: GHOSTTY_POINT_SCREEN, y: y)))
        }
        for y in [0, 1, rows - 1] { parts.append("viewport[\(y)]=" + short(surface.debugReadRow(tag: GHOSTTY_POINT_VIEWPORT, y: y))) }
        for y in [0, 1, rows - 1] { parts.append("active[\(y)]=" + short(surface.debugReadRow(tag: GHOSTTY_POINT_ACTIVE, y: y))) }
        for y in [0, rows - 1] { parts.append("history[\(y)]=" + short(surface.debugReadRow(tag: GHOSTTY_POINT_SURFACE, y: y))) }
        if let rect = surface.debugScreenRectangle() {
            let lines = rect.split(separator: "\n", omittingEmptySubsequences: false)
            parts.append("rect.lines=\(lines.count) rect[0]=\(short(lines.first.map(String.init))) rect[last]=\(short(lines.last.map(String.init)))")
            if total > 0, total - 1 < lines.count { parts.append("rect[total-1]=" + short(String(lines[total - 1]))) }
        }
        if let full = surface.screenText() { parts.append("screenText.lines=\(full.split(separator: "\n", omittingEmptySubsequences: false).count)") }
        return parts.joined(separator: " | ")
    }

    /// DEBUG diagnostics for the demo timeline.
    var debugState: String {
        let grid = surface.grid
        return "sb=\(scrollbar.total)/\(scrollbar.offset)/\(scrollbar.visible) doc=\(originRow)+\(documentRows) top=\(viewportTop) rows=\(surfaceRows) tui=\(tuiRows) grid=\(grid.columns)x\(grid.rows) cell=\(cell) off=\(Int(scrollView.contentOffset.y)) size=\(Int(scrollView.contentSize.height)) inset=\(Int(scrollView.contentInset.top)),\(Int(scrollView.contentInset.bottom)) follow=\(following) cursor=\(surface.cursorViewportRow.map(String.init) ?? "-") draws=\(surface.draws) presents=\(surface.presents) presented=\(presentedTop) pacing(frames/hitches/longestMs/stepMs)=\(FlingAnimator.pacing.frames)/\(FlingAnimator.pacing.hitches)/\(String(format: "%.1f", FlingAnimator.pacing.longestMs))/\(String(format: "%.2f", FlingAnimator.pacing.stepMs)) kbguide=\(Int(keyboardDock.guide.layoutFrame.minY)) stack=\(Int(bottomStack.frame.minY))-\(Int(bottomStack.frame.maxY)) keybar=\(Int(keyBarClip.frame.minY))-\(Int(keyBarClip.frame.maxY)) view=\(Int(view.bounds.height)) safe=\(Int(view.safeAreaInsets.top)),\(Int(view.safeAreaInsets.bottom))"
    }
    #endif

    // MARK: Session

    /// Output waiting for the next display frame (see `pumpOutput`).
    private var output = TerminalOutputQueue()
    /// Runs while output is waiting; stopped when the queue is drained.
    private var outputLink: CADisplayLink?
    /// One batch with Ghostty at a time, one started per display frame, and
    /// never mid-burst (`TerminalFeedPacer`, r13 D1). `-CmuxMobileNoBurstHold` for A/B.
    private var pacer = TerminalFeedPacer(holdsBursts: !CommandLine.arguments.contains("-CmuxMobileNoBurstHold"))
    private var feedInFlight: Bool { pacer.inFlight }
    /// Wakes the pump when output waits only for its burst to end.
    private var burstWake: DispatchWorkItem?
    private var burstWakeTime: CFTimeInterval = 0
    /// The session was asked to stop delivering output (the queue is over its high water).
    private var outputPaused = false
    /// The row shift's state; used only on the surface's output queue, in feed order.
    private let rowShift = RowShiftBox()

    private func sessionEvent(_ event: TerminalSessionEvent) {
        switch event {
        case .output(let data):
            let isReset = data == Self.mirrorReset
            if isReset {
                sizingLog.notice("mirror reset cause=session-reset (the session's replay follows)")
                // The rows being read are rebuilt from the replay: a reader
                // goes back to their rows once it is in (V2-3,
                // TerminalReadingMark); otherwise to the prompt.
                markReadingPosition()
                freezeLastFrame()
                // Held already (a second reset, D4): the frame that releases
                // it is one placed after this reset's replay.
                placedSinceHold = false
                freezeBatches = 0
                // A second reset (D4) waits for its own replay.
                readingMarkAwaitsReport = false
                scroll.reset()
                armReplayDeadline()
            }
            if isReset {
                replayStartedAt = CACurrentMediaTime()
                replayBytes = 0
            } else if replayGate.isReplaying {
                replayBytes += data.count
            }
            replayGate.received(data.count, isReset: isReset, at: CACurrentMediaTime())
            pacer.arrived(at: CACurrentMediaTime())
            #if DEBUG
            if TerminalFrameLog.isEnabled { frameLog.outputArrived() }
            #endif
            // Per chunk: queue the bytes and nothing else. Parsing, the row
            // shift and the artifact scan happen once per display frame.
            model.ingest(event)
            output.append(data)
            if !outputPaused, output.isOverHighWater {
                outputPaused = true
                model.session.setOutputPaused(true)
            }
            scheduleOutput()
        case .alternateScreen(let on):
            // In order with the bytes: applied once the bytes before it were parsed.
            output.append(alternateScreen: on)
            scheduleOutput()
        case .hostGrid(let columns, let rows):
            // In order with the bytes too: the mirror takes the Mac's new
            // grid right before the first byte drawn for it.
            output.append(hostGrid: columns, rows: rows)
            scheduleOutput()
        case .hostGridOwner(let name):
            hostGridOwner = name
        default:
            model.ingest(event)
        }
    }

    /// Feeds at once when nothing was fed in this display frame (an echo is
    /// not held back to the next frame); otherwise the display link feeds at
    /// the start of the next frame. Either way, at most one batch per frame.
    private func scheduleOutput() {
        if pacer.canFeed(at: CACurrentMediaTime()) {
            pumpOutput()
        } else {
            armBurstWake()
        }
        guard outputLink == nil, !output.isEmpty || feedInFlight else { return }
        let link = CADisplayLink(target: DisplayLinkProxy(owner: self) { [weak self] in
            // A new frame: one more batch may go.
            self?.pacer.newFrame()
            self?.pumpOutput()
        }, selector: #selector(DisplayLinkProxy.step(_:)))
        link.preferredFrameRateRange = .terminal
        link.add(to: .main, forMode: .common)
        outputLink = link
    }

    private var frameInterval: CFTimeInterval {
        let fps = view.window?.screen.maximumFramesPerSecond ?? 60
        return 1 / Double(max(30, fps))
    }

    /// One display frame: hands Ghostty the next batch (at most
    /// `TerminalOutputQueue.frameBudget` bytes) when the previous one is
    /// parsed, applying alternate screen switches in order on the way.
    /// Output waits only for its burst to end (no display frame may come
    /// first: the link stops when nothing is in flight): look again then.
    private func armBurstWake() {
        guard let wake = pacer.wakeTime(at: CACurrentMediaTime()) else { return }
        if burstWake != nil, burstWakeTime <= wake { return }
        burstWake?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.burstWake = nil
                self.pumpOutput()
            }
        }
        burstWake = item
        burstWakeTime = wake
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, wake - CACurrentMediaTime()), execute: item)
    }

    private func pumpOutput() {
        guard pacer.canFeed(at: CACurrentMediaTime()) else {
            armBurstWake()
            return
        }
        while !feedInFlight, let step = output.next(budget: TerminalOutputQueue.budget(interacting: scroll.isInteracting && !Self.legacyInteraction)) {
            switch step {
            case .alternateScreen(let on):
                model.ingest(.alternateScreen(on))
                applyMode(tui: on)
            case .hostGrid(let columns, let rows):
                appliedHostColumns = columns
                appliedHostRows = rows
                syncHostGrid()
            case .bytes(let data):
                syncHostGrid()
                pacer.started(frameEnd: outputLink?.targetTimestamp ?? CACurrentMediaTime() + frameInterval,
                              queueEmpty: output.isEmpty)
                model.scanOutput(data)
                #if DEBUG
                devProbe?.fed(data)
                #endif
                let transform: (@Sendable (Data) -> Data)?
                if let remote = model.session.remoteRows {
                    let offset = max(0, surface.grid.rows - remote)
                    let box = rowShift
                    transform = { box.filter($0, offset: offset, remoteRows: remote) }
                } else {
                    transform = nil
                }
                let raw = data.count
                surface.feed(data, transform: transform) { [weak self] in
                    guard let self else { return }
                    self.measured("output-batch") { self.outputProcessed(raw) }
                }
            }
        }
        if outputPaused, output.isUnderLowWater {
            outputPaused = false
            model.session.setOutputPaused(false)
        }
        if output.isEmpty, !feedInFlight {
            pacer.drained()
            stopOutputLink()
        }
    }

    private func stopOutputLink() {
        outputLink?.invalidate()
        outputLink = nil
    }

    /// Ghostty pruned `rows` of its oldest rows (`TerminalHistoryPrune`):
    /// everything held in absolute rows moves up by them, and the offset with
    /// the document, in this transaction, so the rows on screen stay put
    /// (also mid-fling: UIKit's deceleration and the fling continue from the
    /// moved offset).
    private func historyPruned(_ rows: Int) {
        sizingLog.notice("history pruned \(rows, privacy: .public) rows at the top (total \(self.scrollbar.total, privacy: .public)): rows held move up")
        scroll.shiftRows(by: -rows)
        presentedTop -= rows
        viewportTop = max(0, viewportTop - rows)
        viewportTracker.shiftRows(by: -rows)
        recentTops = recentTops.map { max(0, $0 - rows) }
        steadyViewport = nil
        restoredMark = nil
        guard let current = document, cell.height > 0 else { return }
        let next = TerminalDocumentLayout(originRow: current.originRow - rows, endRow: current.endRow - rows)
        let reference = max(current.originRow, presentedTop + rows)
        let shiftY = next.contentY(ofRow: reference - rows, cellHeight: cell.height) - current.contentY(ofRow: reference, cellHeight: cell.height)
        document = next
        documentTotal = max(0, documentTotal - rows)
        settingOffset = true
        // The offset first: following, the page is at the end, and a shorter
        // content size set first clamps the offset to the new end, after
        // which the shift moved it up a second time.
        if shiftY != 0 { scrollView.contentOffset.y += shiftY }
        setContentHeight(next.contentHeight(cellHeight: cell.height))
        settingOffset = false
        place(atRow: presentedTop)
        selection.shiftRows(by: -rows)
    }

    /// Ghostty's rows in the scrollbar's numbering (`TerminalRowSpace`): the
    /// last reported total and viewport top. Each read goes to Ghostty in a
    /// numbering that addresses the row, or reads nil.
    private var rowReader: TerminalRowReader {
        surface.rowReader(totalRows: scrollbar.total, viewportTop: scrollbar.offset)
    }

    /// The reader's rows kept over a mirror reset (V2-3).
    private var readingMark: TerminalReadingMark?
    /// The replay is parsed; the mark is placed at the next scrollbar report.
    private var readingMarkAwaitsReport = false

    /// The reset's replay is parsed: put a reader back on their rows.
    private func restoreReadingMark() {
        guard let mark = readingMark else { return }
        readingMark = nil
        readingMarkAwaitsReport = false
        guard !model.isTUI, !scrollView.isTracking, !scrollView.isDecelerating else { return }
        let total = scrollbar.total
        let reader = rowReader
        // Every row of the replay, read once (the whole-screen read is not
        // clamped to the grid; round 9): the rows far from the end are found
        // by their text too, so output during the drop cannot push the reader
        // down (T-LIFE-09/15). Rows past the read's trimmed end use the reader.
        let screen = surface.screenRows()
        guard let anchor = mark.locate(totalRows: total, rowText: { row in
            if let screen, row < screen.count { return screen.rows[row] }
            return reader.text(TerminalAbsoluteRow(row))
        }) else { return }
        sizingLog.notice("reading mark restored row \(mark.row, privacy: .public) -> \(anchor.row, privacy: .public) of \(total, privacy: .public)")
        scroll.restoreReading(anchor)
        restoredMark = (mark, anchor)
    }

    /// The last mark restored and where it put the reader; reused when another
    /// reset comes before the reader moves (V3-1: a second reset read the
    /// rows at a misplaced restore, found them blank, and left a black page).
    private var restoredMark: (mark: TerminalReadingMark, anchor: TerminalScrollModel.Anchor)?

    /// At a reset: where the reader is, from the rows on screen, whatever the
    /// scroll state. Mid-fling or mid-drag counts too (V3-3: a drop during a
    /// fling lost the place, since only a settled reader was marked); a fling
    /// stops so the restore can land. Near the bottom, nothing: follow.
    private func markReadingPosition() {
        guard !model.isTUI, readingMark == nil, cell.height > 0 else { return }
        let anchor: TerminalScrollModel.Anchor?
        switch scroll.state {
        case .following:
            anchor = nil
        case .reading(let reading):
            anchor = reading
        case .interacting:
            if let document, scrollView.contentOffset.y < maxOffsetY - TerminalScrollModel.followSlackRows * cell.height {
                anchor = TerminalScrollModel.anchor(offsetY: scrollView.contentOffset.y, layout: document, rowHeight: cell.height)
            } else {
                anchor = nil
            }
        }
        guard let anchor else {
            restoredMark = nil
            return
        }
        if scrollView.isDecelerating || fling != nil {
            fling?.stop()
            fling = nil
            settingOffset = true
            scrollView.setContentOffset(scrollView.contentOffset, animated: false)
            settingOffset = false
        }
        if let restored = restoredMark, restored.anchor == anchor {
            // Nothing moved since the last restore: the same rows, not the
            // ones a misplaced restore put on screen.
            readingMark = restored.mark
        } else {
            let reader = rowReader
            readingMark = TerminalReadingMark(anchor: anchor, totalRows: scrollbar.total) { reader.text(TerminalAbsoluteRow($0)) }
        }
        restoredMark = nil
        sizingLog.notice("reading mark row \(anchor.row, privacy: .public) of \(self.scrollbar.total, privacy: .public): \(self.readingMark == nil ? "none" : "kept", privacy: .public)")
    }

    /// The replay gate's own deadline (V3-2): the document is never left
    /// ungrown past it, held frame or not.
    private func armReplayDeadline() {
        DispatchQueue.main.asyncAfter(deadline: .now() + TerminalReplayGate.deadline) { [weak self] in
            guard let self, self.replayGate.expireIfOverdue(at: CACurrentMediaTime()) else { return }
            sizingLog.notice("replay gate expired at its deadline")
            self.outputSinceProbe = true
            self.updateDocument()
            if self.readingMark != nil {
                self.restoreReadingMark()
                self.updateDocument()
            }
            self.applyScroll()
            if let held = self.freezeView, self.readingMark == nil { self.releaseHeldFrameAtCap(ObjectIdentifier(held), recover: true) }
        }
    }

    /// Ghostty parsed a batch (`raw` session bytes).
    private func outputProcessed(_ raw: Int) {
        pacer.finished()
        // A full-screen app taller than the phone: keep its cursor row on screen.
        if model.isTUI, tuiRowShift > 0 || (model.session.remoteRows ?? 0) > tuiRows {
            applyTUIPlacement()
        }
        #if DEBUG
        devProbe?.processed()
        // Every parsed byte, the reset and replay the gate holds included:
        // the bench's echo and drain offsets count them (fleet bench
        // 2026-10-26: a 2-byte gap read idle echo as 413 ms, drain as -1).
        TerminalBenchProbe.shared?.outputProcessed(raw)
        #endif
        let replayDone = replayGate.parsed(raw)
        if replayGate.isReplaying {
            // A reset's replay is still being fed: no layout, no frame swap
            // until all of it is parsed (user report 2026-10-14).
            outputSinceProbe = true
            if output.isEmpty { stopOutputLink() }
            return
        }
        if replayDone {
            if let started = replayStartedAt {
                sizingLog.notice("replay done bytes=\(self.replayBytes, privacy: .public) ms=\(Int((CACurrentMediaTime() - started) * 1000), privacy: .public)")
                replayStartedAt = nil
            }
            outputSinceProbe = true
            // Ghostty's next scrollbar report has the replay's row count.
            if readingMark != nil { readingMarkAwaitsReport = true }
            updateDocument()
        }
        if freezeView != nil, raw > Self.mirrorReset.count || replayDone, replayHasContent() {
            // The replay is parsed and draws something: drop the held frame on
            // the next present (or after one more batch, whichever comes first).
            freezeBatches += 1
            if freezeBatches >= 2, heldFrameMayGo() { unfreeze() }
        }
        if raw > Self.mirrorReset.count { model.liveOutputDrawn() }
        outputSinceProbe = true
        #if DEBUG
        if CommandLine.arguments.contains("-CmuxMobileTermLog") { NSLog("mobileterm processed %@", debugState) }
        #endif
        if refreshAfterTUI, !model.isTUI {
            // The switch back from the alternate screen is processed by
            // now: ask for the primary screen's viewport and its report.
            refreshAfterTUI = false
            surface.scrollToActiveArea()
        }
        if scrollbar.total == 0 { scrollbar = (surface.grid.rows, 0, surface.grid.rows) }
        updateDocument()
        if output.isEmpty { stopOutputLink() }
    }

    private func surfaceEvent(_ event: TerminalSurfaceEvent) {
        switch event {
        case .scrollbar(let total, let offset, let visible):
            measured("scrollbar") { scrollbarReported(total: total, offset: offset, visible: visible) }
        case .cellSize:
            view.setNeedsLayout()
        case .bell:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    private func scrollbarReported(total: Int, offset: Int, visible: Int) {
        let previous = scrollbar
        // The new report first: the shift below scrolls the page, and the
        // viewport check it runs must see Ghostty's viewport in the new
        // numbering (in the old one, a followed end looked far below the
        // rows on screen and was asked to move into the scrollback).
        scrollbar = (total, offset, visible)
        viewportTracker.report()
        if !model.isTUI, !replayGate.isReplaying,
           let pruned = TerminalHistoryPrune.prunedRows(previousTotal: previous.total, previousOffset: previous.offset,
                                                         total: total, offset: offset, requestedTop: viewportTop,
                                                         rows: max(1, surfaceRows)) {
            historyPruned(pruned)
        }
        let restoring = readingMarkAwaitsReport
        if restoring { restoreReadingMark() }
        updateDocument()
        if restoring { applyScroll() }
        #if DEBUG
        if CommandLine.arguments.contains("-CmuxMobileTermLog") { NSLog("mobileterm scrollbar %@", debugState) }
        #endif
        if placesFromReport, !model.isTUI { place(atRow: offset) }
        // Whatever moved Ghostty's viewport (a request, a cursor probe
        // restoring an older row), it must cover the visible rows; a
        // report that leaves them uncovered asks again. Without this, a
        // reattach replay left the probe's restore at row 0 while the
        // screen showed the bottom: a blank page.
        updateViewport(visibleMinY: scrollView.contentOffset.y)
    }

    // MARK: Held frame (R2-3)

    /// `ESC c`: the session resets the mirror before a replay (a resize, a reattach).
    static let mirrorReset = Data("\u{1B}c".utf8)

    /// Holds what is on screen until the replay after a reset is drawn. Only
    /// once the page has drawn something (the first attach has nothing to hold).
    private func freezeLastFrame() {
        // Never while the page is being scrolled: the still would stand over
        // the moving rows and show an older position until the replay was in
        // (user report 2026-10-14, frames alternating near the bottom).
        guard freezeView == nil, view.window != nil, document != nil || model.isTUI,
              !scrollView.isTracking, !scrollView.isDecelerating,
              let snapshot = view.snapshotView(afterScreenUpdates: false) else { return }
        snapshot.frame = view.bounds
        snapshot.isUserInteractionEnabled = false
        view.insertSubview(snapshot, belowSubview: bottomBacking)
        freezeView = snapshot
        freezeBatches = 0
        placedSinceHold = false
        // A TUI's replay at a new size can be an empty alternate screen until
        // the program repaints (R3-2: `top` waits for its 1 s tick); the held
        // frame waits for that, but never longer than this.
        freezeStarted = CACurrentMediaTime()
        let held = ObjectIdentifier(snapshot)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.freezeCap) { [weak self] in
            guard let self, let view = self.freezeView, ObjectIdentifier(view) == held else { return }
            if self.replayGate.isReplaying {
                self.replayGate.expire()
                self.outputSinceProbe = true
                self.updateDocument()
            }
            if self.readingMark != nil {
                self.restoreReadingMark()
                self.updateDocument()
                self.applyScroll()
            }
            self.releaseHeldFrameAtCap(held, recover: true)
        }
    }

    /// The held frame at its cap (termqa N1): it goes only once the frame
    /// placed covers the rows the page shows, else the frame is placed again
    /// (by the report, or asked for) and the held frame stays until a
    /// present releases it (`heldFrameMayGo`) or `coverCap` passes.
    private func releaseHeldFrameAtCap(_ held: ObjectIdentifier, recover: Bool) {
        guard let view = freezeView, ObjectIdentifier(view) == held else { return }
        let elapsed = CACurrentMediaTime() - freezeStarted
        guard !model.isTUI, cell.height > 0, surfaceRows > 0, let document else {
            unfreeze()
            return
        }
        let visible = visibleRowRange
        if TerminalHeldFrame.releasesAtCap(isAlternate: false, cover: TerminalFrameCover(presentedTop: presentedTop, surfaceRows: surfaceRows),
                                           visibleTop: visible.lowerBound, visibleBottom: visible.upperBound,
                                           documentRows: document.originRow..<document.endRow, elapsed: elapsed) {
            unfreeze()
            return
        }
        if recover {
            sizingLog.notice("held frame kept at the cap: rows \(visible.lowerBound, privacy: .public)..<\(visible.upperBound, privacy: .public) not in the frame at \(self.presentedTop, privacy: .public) (report \(self.scrollbar.offset, privacy: .public), request \(self.viewportTop, privacy: .public))")
            placeFrameAgain(visible: visible)
        }
        // The next present releases it once its frame covers the page; this
        // is the bound.
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, TerminalHeldFrame.coverCap - elapsed)) { [weak self] in
            self?.releaseHeldFrameAtCap(held, recover: false)
        }
    }

    /// The longest a held frame stays up after a reset.
    static let freezeCap: TimeInterval = TerminalHeldFrame.cap

    /// Whether the new screen has enough to show (`TerminalHeldFrame`): on the
    /// alternate screen, 30 % of the TUI's rows with text; a shell's replay
    /// once it has any text.
    private func replayHasContent() -> Bool {
        let rows = model.isTUI ? max(1, tuiRows) : max(1, surface.grid.rows)
        guard let text = surface.activeAreaText() else { return true }
        return TerminalHeldFrame().shouldRelease(isAlternate: model.isTUI,
                                                 nonBlankRows: TerminalHeldFrame.nonBlankRows(in: text, limit: rows),
                                                 rows: rows, elapsed: CACurrentMediaTime() - freezeStarted)
    }

    private func unfreeze() {
        freezeView?.removeFromSuperview()
        freezeView = nil
        freezeBatches = 0
    }

    /// Shows the bottom fade while rows are scrolled under the composer.
    private func updateBottomFade() {
        // Only when rows are really under the composer (following rests on
        // the bottom, whatever the insets did mid-animation).
        let under = !model.isTUI && !following && scrollView.contentOffset.y < maxOffsetY - 1
        let alpha: CGFloat = under ? 1 : 0
        if bottomFade.alpha != alpha { bottomFade.alpha = alpha }
        // The soft scroll edge blurs what is under the composer. At the
        // bottom the last row rests on the card and nothing is under it: no
        // edge effect over the last row (user report 2026-10-14).
        if scrollView.bottomEdgeEffect.isHidden == under { scrollView.bottomEdgeEffect.isHidden = !under }
    }

    // MARK: Layout

    private func layoutTerminal() {
        let bounds = view.bounds
        guard bounds.width > 0 else { return }
        // After any layout (the page's size, the insets, the composer): the
        // scroll model places the rows (F4, F8: never past the end, the last
        // row on the composer when following, a reader on their rows).
        defer { applyScroll() }
        #if DEBUG
        if CommandLine.arguments.contains("-CmuxMobileTermLog") {
            NSLog("mobileterm layout kb=%@ stack=%@ view=%@ window=%@", NSCoder.string(for: keyboardDock.guide.layoutFrame), NSCoder.string(for: bottomStack.frame), NSCoder.string(for: view.frame), NSCoder.string(for: view.convert(view.bounds, to: nil)))
        }
        #endif
        let measured = surface.cellSize
        if measured.height > 0 { cell = measured }
        let cellHeight = cell.height > 0 ? cell.height : 16
        // The screen plus a margin above and below the visible rows
        // (TerminalMirrorRows). The rows depend on the screen, not on this
        // layout's height (V2-1: a grid zoom's transient page height resized
        // the mirror mid-stream). Out of a window, the rows stay as they are.
        let screen = view.window?.screen
        let rows = screen == nil && surfaceRows > 0 ? surfaceRows
            : TerminalMirrorRows.rows(pageHeight: bounds.height, screenSize: screen?.bounds.size ?? bounds.size,
                                      cellHeight: cellHeight, scale: screen?.scale ?? surface.renderScale, marginRows: Self.marginRows)
        if rows != surfaceRows {
            sizingLog.notice("mirror rows \(self.surfaceRows, privacy: .public) -> \(rows, privacy: .public) cause=layout page \(Int(bounds.height), privacy: .public)pt")
            surfaceRows = rows
            viewportTop = -1
        }
        let layout = hostLayout
        mirrorWidth = layout.surfaceWidth
        let surfaceSize = CGSize(width: layout.surfaceWidth, height: CGFloat(rows) * cellHeight)
        if surface.bounds.size != surfaceSize {
            UIView.performWithoutAnimation {
                surface.frame.size = surfaceSize
                surface.layoutIfNeeded()
            }
        }

        // TUI rows: toolbar bottom to the composer's top where it settled
        // (keyboard down, or up once the keyboard finished showing: R1-1).
        let newTUIRows = tuiSizing.rows(restingStackTop: restingStackTop, chromeTop: chromeTop, cellHeight: cellHeight)
        // The phone claims its own grid; only the rendering follows the Mac's.
        let columns = layout.phoneColumns
        if newTUIRows != tuiRows || columns != gridColumns {
            tuiRows = newTUIRows
            gridColumns = columns
            tuiHeight.constant = CGFloat(tuiRows) * cellHeight
        }
        if columns > 0 { measuredGrid(columns: columns, rows: newTUIRows) }
        applyContentWidth()
        applyTUIPlacement()

        // Insets: content starts under the toolbar and ends above the composer.
        let top = chromeTop
        // The last row rests 8 pt above the composer card (SPEC M3).
        let bottom = TerminalDocumentLayout.bottomInset(pageHeight: bounds.height, composerTop: bottomStack.frame.minY)
        let insets = UIEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        if scrollView.contentInset != insets {
            let previousOffset = scrollView.contentOffset.y
            scrollView.contentInset = insets
            scrollView.verticalScrollIndicatorInsets = UIEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
            if following || dragPinsToComposer, !model.isTUI {
                // Rides the keyboard: the offset changes inside the keyboard's
                // animation; the surface covers both ends of it.
                updateViewport(visibleMinY: min(previousOffset, maxOffsetY))
                if dragPinsToComposer {
                    settingOffset = true
                    scrollView.contentOffset.y = maxOffsetY
                    settingOffset = false
                }
            }
        }
    }

    private var maxOffsetY: CGFloat {
        TerminalDocumentLayout.bottomOffset(contentHeight: scrollView.contentSize.height, viewportHeight: scrollView.bounds.height,
                                            topInset: scrollView.contentInset.top, bottomInset: scrollView.contentInset.bottom)
    }

    /// Recomputes the document height from Ghostty's scrollbar and the cursor.
    private func updateDocument() {
        guard !model.isTUI, cell.height > 0, !replayGate.isReplaying else { return }
        // The document only grows with output (the total changes); probing the
        // cursor moves Ghostty's viewport for a moment, so it is not repeated
        // for reports that only moved the viewport (scrolling).
        guard scrollbar.total != documentTotal || document == nil || outputSinceProbe else { return }
        // A finger or a deceleration owns the page: grow the end by the new
        // rows and read nothing under Ghostty's lock (user report
        // 2026-10-14: a drag stuttered while an agent streamed). The page is
        // measured again when the gesture ends (settleScroll).
        if scroll.isInteracting, !Self.legacyInteraction, let current = document, scrollbar.total >= documentTotal, !placesFromReport {
            let next = current.grown(fromTotal: documentTotal, toTotal: scrollbar.total)
            documentTotal = scrollbar.total
            measureAfterGesture = true
            if next != current {
                document = next
                setContentHeight(next.contentHeight(cellHeight: cell.height))
            }
            return
        }
        // The scrollback shrank (`clear`, ESC [3J): the rows the user was
        // reading are gone. Follow the prompt again, like Terminal.
        if scrollbar.total < documentTotal, scrollbar.total <= max(surface.grid.rows, 1) { scroll.reset() }
        let previousTotal = documentTotal
        documentTotal = scrollbar.total
        outputSinceProbe = false
        // The cursor's row: read when it is in the viewport; while the page
        // shows older rows, its last distance from the end (an inline TUI
        // keeps its input box at the same place from the bottom).
        // Against Ghostty's viewport as last reported, or as last asked for
        // when the request is newer: a request inside the active area
        // follows it, so an older request put the cursor rows above where
        // it is drawn (termqa N3).
        var cursor = surface.cursorViewportRow.map {
            viewportTracker.cursorRow(viewportRow: $0, reportedOffset: scrollbar.offset, totalRows: scrollbar.total,
                                      gridRows: surface.grid.rows)
        }
        if let cursor {
            cursorRowsFromEnd = max(0, scrollbar.total - 1 - cursor)
        } else if let distance = cursorRowsFromEnd {
            cursor = max(0, scrollbar.total - 1 - distance)
        }
        var blank: Int? = document?.originRow
        if model.session.remoteRows == nil {
            // A local session writes from row 0: no mirror rows above it.
            blank = 0
        } else if placesFromReport || TerminalDocumentLayout.needsOriginScan(previous: document, previousTotal: previousTotal,
                                                                             totalRows: scrollbar.total, screenRows: surface.grid.rows) {
            // Back from a TUI (until the user scrolls) the primary screen is
            // being redrawn and resized: read the top again on every update,
            // so earlier output is never left above an origin read too early (R2-1).
            let last = min(scrollbar.total - 1, cursor ?? (scrollbar.total - 1))
            blank = rowReader.leadingBlankRows(through: TerminalAbsoluteRow(max(0, last))) ?? blank
        }
        // Rows an inline TUI draws below the cursor (Codex CLI's hints).
        var lastContent: Int?
        if let cursor, cursor + 1 <= scrollbar.total - 1 {
            lastContent = rowReader.lastNonBlankRow(from: TerminalAbsoluteRow(cursor + 1), through: TerminalAbsoluteRow(scrollbar.total - 1))?.index
        }
        let measured = TerminalDocumentLayout.make(totalRows: scrollbar.total, cursorRow: cursor, leadingBlankRows: blank,
                                                   lastContentRow: lastContent)
        if document == nil { endHold.reset() }
        // The Mac's screen is the bottom `remoteRows` rows of the mirror.
        let screenTop = max(0, scrollbar.total - (model.session.remoteRows ?? surface.grid.rows))
        let next = endHold.hold(measured, totalRows: scrollbar.total, cursorRow: cursor, screenTopRow: screenTop)
        guard next != document else { return }
        let shift = CGFloat(next.originRow - originRow) * cell.height
        let hadDocument = document != nil
        document = next
        setContentHeight(next.contentHeight(cellHeight: cell.height))
        if hadDocument, shift != 0 {
            // The top moved (cleared, or found): the frame on screen goes
            // where its rows now belong.
            place(atRow: presentedTop)
            selection.redraw()
            tuiSelection.redraw()
        }
        // The scroll model places the rows: the bottom when following, the
        // anchored rows when reading, nothing while a finger owns the page.
        applyScroll(fromOutput: true)
    }

    /// Input is about to go to the program: on the primary screen, follow
    /// the output again and jump to the prompt if the user scrolled away.
    /// (Output alone never moves someone who scrolled up; typing does.)
    private func revealCursorForInput() {
        followCursorColumn()
        guard cell.height > 0, !model.isTUI else { return }
        fling?.stop()
        fling = nil
        scroll.input()
        applyScroll()
    }

    /// Rows kept rendered above and below the visible rows. A frame for a new
    /// viewport takes a few display frames to arrive; a fling at 9000 pt/s
    /// moves about 5 rows per 120 Hz frame, so the previous frame must still
    /// cover the screen for several of them.
    static let marginRows = 48

    /// Leading and trailing padding of the grid inside the page (SPEC M5):
    /// the first and last columns clear the display's corner radius. The
    /// background still fills the page edge to edge.
    static let sidePadding: CGFloat = 6

    /// Asks Ghostty for a viewport that covers the visible rows with margin on
    /// both sides, once the visible rows come within half a margin of the
    /// requested viewport's edges. The surface itself moves only when a frame
    /// for the new viewport is presented (`surfacePresented`).
    private func updateViewport(visibleMinY requested: CGFloat, force: Bool = false) {
        guard !model.isTUI, cell.height > 0, surfaceRows > 0 else { return }
        // A move waiting for its frame asks only for its target's rows (qa11
        // wt-fling-c/d: a report or an inset change asked again for the
        // reader's rows, and that frame came after the end's).
        let visibleMinY = TerminalScrollGate.requestOffset(awaiting: followAwaitsPresent, current: requested,
                                                           target: followAwaitsPresent ? pendingTarget : nil)
        let maxTop = max(0, scrollbar.total - surfaceRows)
        let visibleTop = originRow + Int(floor(max(0, visibleMinY) / cell.height))
        let visibleBottom = originRow + Int(ceil((max(0, visibleMinY) + view.bounds.height) / cell.height))
        let margin = (surfaceRows - Int(ceil(view.bounds.height / cell.height))) / 2
        // Ghostty's viewport as last reported; it may follow the output on its
        // own (a request inside the active area keeps it at the bottom).
        let current = scrollbar.total > 0 ? scrollbar.offset : viewportTop
        let needsNew = current < 0
            || (visibleTop < current + margin / 2 && current > 0)
            || (visibleBottom > current + surfaceRows - margin / 2 && current < maxTop)
            || current > maxTop
        guard needsNew || force else { return }
        let top = min(max(0, visibleTop - margin), maxTop)
        guard top != current || force else { return }
        // Ghostty reports a viewport other than the one last asked for (a
        // cursor probe or a reset moved it): ask again rather than wait for a
        // report that will not come, which left the visible rows blank.
        if top != viewportTop {
            recentTops.append(viewportTop)
            if recentTops.count > 6 { recentTops.removeFirst() }
            viewportTop = top
        } else if scrollbar.total == 0 {
            return
        }
        #if DEBUG
        if CommandLine.arguments.contains("-CmuxMobileTermLog") { NSLog("mobileterm request %d (current %d visibleTop %d)", top, current, visibleTop) }
        #endif
        viewportTracker.request(top)
        measured("viewport-request") { surface.scroll(toRow: top) }
    }

    /// A frame was presented: put the surface where its rows belong, in the
    /// same transaction. Ghostty renders on its own thread and its viewport
    /// reports (scrollbar) and frames reach the main thread in either order,
    /// and a frame rendered before a request can arrive after it. So the
    /// frame's viewport is read from its pixels: its cell rows are matched
    /// against the previous frame's rows for the candidate shifts (none, the
    /// last report, the last request), and the best match places it.
    private func surfacePresented() {
        #if DEBUG
        TerminalBenchProbe.shared?.presented()
        devProbe?.presented()
        #endif
        // A TUI's screen has no scroll: the held frame goes once the replay drew.
        if model.isTUI, freezeView != nil, heldFrameMayGo() { unfreeze() }
        guard !model.isTUI, cell.height > 0 else { return }
        let scale = view.window?.screen.scale ?? surface.renderScale
        let rowPixels = Int((cell.height * scale).rounded())
        var top = scrollbar.offset
        #if DEBUG
        presentDebug = ""
        #endif
        let match = TerminalPresentMatch(presentedTop: presentedTop, reportedTop: scrollbar.offset, requestedTop: viewportTop,
                                         recentRequests: recentTops, activeTop: max(0, scrollbar.total - surfaceRows),
                                         requestIsNewer: viewportTop >= 0 && !viewportTracker.reportedSinceRequest)
        let epoch = surface.viewportEpoch
        if !placesFromReport, let known = match.knownTop(steady: steadyViewport, epoch: epoch) {
            // Reading scrollback while output streams: the viewport has not
            // moved since a read frame confirmed it, so no pixel read.
            top = known
            presentSkips += 1
            #if DEBUG
            presentDebug = " steady"
            #endif
        } else if let rows = measured("present-read", { surface.presentedRowSignatures(rowHeight: rowPixels, band: presentReadBand) }) {
            steadyViewport = nil
            if let previous = presentedRows {
                let result = match.match(previous: previous, current: rows)
                top = result.top
                #if DEBUG
                if !result.matched, top != presentedTop, TerminalFrameLog.isEnabled {
                    sizingLog.notice("present: no match, placed at \(top, privacy: .public) (was \(self.presentedTop, privacy: .public), report \(self.scrollbar.offset, privacy: .public), request \(self.viewportTop, privacy: .public)\(match.requestIsNewer ? ", newer" : "", privacy: .public))")
                }
                #endif
                steadyViewport = placesFromReport ? nil : match.confirmed(result, epoch: epoch)
                #if DEBUG
                if CommandLine.arguments.contains("-CmuxMobilePresentLog") {
                    presentDebug = match.candidateShifts.map { String(format: " %d:%.2f", $0, TerminalPresentMatch.score(previous, rows, shift: $0)) }.joined()
                }
                #endif
            }
            presentedRows = rows
            presentReads += 1
        }
        #if DEBUG
        if CommandLine.arguments.contains("-CmuxMobilePresentLog") {
            presentLog.append(String(format: "%.4f wall=%.4f top=%d prev=%d sb=%d req=%d off=%.1f", CACurrentMediaTime(), Date().timeIntervalSince1970, top, presentedTop, scrollbar.offset, viewportTop, scrollView.contentOffset.y) + " " + presentDebug)
        }
        #endif
        place(atRow: placesFromReport ? scrollbar.offset : top)
        if followAwaitsPresent { applyScroll() }
        // A reader's rows are placed first (V2-3), and the held frame goes
        // only once the frame just placed covers the rows the page shows
        // (qa11 wt-read2-a: a frame of the end released it over the
        // reader's rows, one black frame).
        if freezeView != nil {
            placedSinceHold = true
            if heldFrameMayGo() { unfreeze() }
        }
    }

    /// A frame was placed since the frame was held (`presentedTop` is in
    /// the replay's numbering).
    private var placedSinceHold = false

    /// The held frame may go (`TerminalHeldFrame.releasesOnPresent`).
    private func heldFrameMayGo() -> Bool {
        guard model.isTUI || (placedSinceHold && document != nil && cell.height > 0) else { return false }
        let visible = model.isTUI ? 0..<0 : visibleRowRange
        return TerminalHeldFrame.releasesOnPresent(isAlternate: model.isTUI, replayDrawn: freezeBatches > 0, markPending: readingMark != nil,
                                                   cover: TerminalFrameCover(presentedTop: presentedTop, surfaceRows: surfaceRows),
                                                   visibleTop: visible.lowerBound, visibleBottom: visible.upperBound,
                                                   documentRows: (document?.originRow ?? 0)..<(document?.endRow ?? 0))
    }

    /// While following, a present reads only the rows on screen and 16 rows
    /// on each side (round 7: the full 151-row read cost p99 3.36 ms a
    /// frame). Every other phase reads the whole frame. `-CmuxMobileFullPresentRead`
    /// for A/B.
    private var presentReadBand: Range<Int>? {
        guard following, !scroll.isInteracting, cell.height > 0, surfaceRows > 0,
              !Self.fullPresentRead else { return nil }
        let visibleTop = scrollView.contentOffset.y - surface.frame.minY
        let first = Int(floor(visibleTop / cell.height))
        let last = Int(ceil((visibleTop + scrollView.bounds.height) / cell.height))
        return TerminalPresentMatch.readBand(visible: first..<max(first, last), rowCount: surfaceRows, margin: 16)
    }
    private static let fullPresentRead = CommandLine.arguments.contains("-CmuxMobileFullPresentRead")

    /// Following output waits for the frame that shows it; if none comes
    /// within two display frames (nothing visible changed), it moves anyway.
    private var followAwaitsPresent = false
    private var followFallback: CADisplayLink?
    private var followFallbackTicks = 0
    private var followFallbackLimit = 2
    /// The fallback moves the page even if no frame covers it yet.
    private var forceScroll = false

    /// When the current wait for a frame began (`TerminalScrollGate.maxWait`).
    private var awaitStarted: CFTimeInterval?

    /// The page keeps its frame and waits for Ghostty's next one.
    private func awaitFrame(ticks: Int) {
        if !followAwaitsPresent || awaitStarted == nil { awaitStarted = CACurrentMediaTime() }
        followAwaitsPresent = true
        armFollowFallback(ticks: ticks)
    }

    /// The scroll model's target `target` (content y) shows only rows the
    /// frame on screen covers (`TerminalScrollGate`).
    private func targetCovered(_ target: CGFloat) -> Bool {
        guard let document, surfaceRows > 0, cell.height > 0 else { return true }
        let top = originRow + Int(floor(max(0, target) / cell.height))
        let bottom = originRow + Int(ceil((max(0, target) + view.bounds.height) / cell.height))
        return TerminalScrollGate.movesNow(cover: TerminalFrameCover(presentedTop: presentedTop, surfaceRows: surfaceRows),
                                           visibleTop: top, visibleBottom: bottom, documentRows: document.originRow..<document.endRow)
    }

    /// An offscreen page waits for no frame: the next output or appearance
    /// asks again (round 11 A3: the wait never ended for a page that left).
    private func stopFollowFallback() {
        followFallback?.invalidate()
        followFallback = nil
        followAwaitsPresent = false
        awaitStarted = nil
    }

    private func armFollowFallback(ticks: Int = 2) {
        followFallbackLimit = max(ticks, followFallback == nil ? 0 : followFallbackLimit)
        guard followFallback == nil else { return }
        followFallbackTicks = 0
        let link = CADisplayLink(target: DisplayLinkProxy(owner: self) { [weak self] in
            guard let self else { return }
            guard self.view.window != nil else { return self.stopFollowFallback() }
            self.followFallbackTicks += 1
            guard self.followFallbackTicks >= self.followFallbackLimit || !self.followAwaitsPresent else { return }
            let waited = CACurrentMediaTime() - (self.awaitStarted ?? CACurrentMediaTime())
            if self.followAwaitsPresent, let target = self.pendingTarget,
               !TerminalScrollGate.fallbackMoves(covered: self.targetCovered(target), waited: waited) {
                // The frame for the target is not in yet (fast output, a
                // busy renderer): the page keeps the frame it has rather
                // than move to rows it does not cover (V8 claim 1a, qa11
                // wt-fling-c/d: never, however long). Past the maximum wait
                // it goes as far as the frame's rows reach. Ask again for the
                // viewport and a frame, and check next frame.
                if waited >= TerminalScrollGate.maxWait, let document = self.document {
                    let y = TerminalScrollGate.fallbackOffset(frame: self.surface.frame.minY..<self.surface.frame.maxY,
                                                              target: target, viewport: self.view.bounds.height)
                    if abs(y - self.scrollView.contentOffset.y) > 0.5, y >= -self.scrollView.contentInset.top,
                       y <= document.contentHeight(cellHeight: self.cell.height) {
                        self.settingOffset = true
                        self.scrollView.contentOffset.y = y
                        self.settingOffset = false
                        self.updateBottomFade()
                    }
                }
                if self.followFallbackTicks % 6 == 0 {
                    self.updateViewport(visibleMinY: target, force: true)
                    self.surface.setNeedsTerminalDraw()
                }
                return
            }
            self.followFallback?.invalidate()
            self.followFallback = nil
            if self.followAwaitsPresent {
                self.forceScroll = true
                self.applyScroll()
                self.forceScroll = false
            }
        }, selector: #selector(DisplayLinkProxy.step(_:)))
        link.preferredFrameRateRange = .terminal
        link.add(to: .main, forMode: .common)
        followFallback = link
    }

    /// The scroll model's target now, when the page is not moved by UIKit.
    private var pendingTarget: CGFloat? {
        guard !model.isTUI, cell.height > 0 else { return nil }
        return scroll.target(layout: document, rowHeight: cell.height, topInset: scrollView.contentInset.top, bottomOffsetY: maxOffsetY)
    }

    // MARK: Blank page watch (V6-2, V6-3, V6-4)

    private var blankWatch = TerminalBlankWatch()
    private var blankToken: FrameClock.Token?

    private func startBlankWatch() {
        guard blankToken == nil else { return }
        blankToken = FrameClock.shared.subscribe { [weak self] tick in self?.checkBlankPage(now: tick.timestamp) }
    }

    private func stopBlankWatch() {
        if let blankToken { FrameClock.shared.unsubscribe(blankToken) }
        blankToken = nil
        blankWatch = TerminalBlankWatch()
    }

    /// The visible rows (absolute) for the page's offset.
    private var visibleRowRange: Range<Int> {
        let minY = max(0, scrollView.contentOffset.y)
        let top = originRow + Int(floor(minY / cell.height))
        let bottom = originRow + Int(ceil((minY + scrollView.bounds.height) / cell.height))
        return top..<max(top, bottom)
    }

    /// Every display frame: does the frame on screen cover the rows the page
    /// shows? A held frame (`freezeView`) covers the page by itself.
    private func checkBlankPage(now: CFTimeInterval) {
        guard !model.isTUI, cell.height > 0, surfaceRows > 0, let document, surface.surface != nil,
              view.window != nil, freezeView == nil else {
            _ = blankWatch.observe(covered: true, now: now)
            return
        }
        let visible = visibleRowRange
        let covered = TerminalBlankWatch.covers(presentedTop: presentedTop, surfaceRows: surfaceRows, visibleTop: visible.lowerBound,
                                                visibleBottom: visible.upperBound, documentRows: document.originRow..<document.endRow)
        guard blankWatch.observe(covered: covered, now: now) else { return }
        recoverBlankPage(visible: visible)
    }

    /// The frame log's `blank`: the legible band (below the top inset,
    /// above the composer) shows at least a row's height of background where
    /// the document has rows (`TerminalBlankWatch.showsBlank`). A held frame
    /// covers the page by itself.
    private var legibleRowsBlank: Bool {
        guard !model.isTUI, cell.height > 0, document != nil, surface.surface != nil, view.window != nil, freezeView == nil else { return false }
        let offset = scrollView.contentOffset.y
        let legibleTop = offset + scrollView.contentInset.top
        let legibleBottom = offset + min(scrollView.bounds.height, bottomStack.frame.minY)
        guard legibleBottom > legibleTop else { return false }
        return TerminalBlankWatch.showsBlank(frame: surface.frame.minY..<surface.frame.maxY,
                                             document: 0..<scrollView.contentSize.height,
                                             legible: legibleTop..<legibleBottom, cellHeight: cell.height)
    }

    /// The page has shown uncovered rows past the deadline: nothing it waits
    /// for is coming (a frame placed in a stale numbering, a request whose
    /// frame never arrived). Place the frame by Ghostty's report when that
    /// covers the rows, forget the frame used for matching (the next one is
    /// placed by the report), and ask Ghostty for a viewport and a frame.
    private func recoverBlankPage(visible: Range<Int>) {
        let reportCovers = TerminalBlankWatch.covers(presentedTop: scrollbar.offset, surfaceRows: surfaceRows, visibleTop: visible.lowerBound,
                                                     visibleBottom: visible.upperBound, documentRows: originRow..<(document?.endRow ?? Int.max))
        sizingLog.notice("blank page: rows \(visible.lowerBound, privacy: .public)..<\(visible.upperBound, privacy: .public) not in the frame at \(self.presentedTop, privacy: .public) (report \(self.scrollbar.offset, privacy: .public), request \(self.viewportTop, privacy: .public)) for \(Int((self.blankWatch.uncoveredSince.map { CACurrentMediaTime() - $0 } ?? 0) * 1000), privacy: .public) ms: \(reportCovers ? "placed by the report" : "asked again", privacy: .public) (event \(self.blankWatch.events, privacy: .public))")
        placeFrameAgain(visible: visible)
    }

    /// Places the frame by Ghostty's report when that covers `visible`, forgets
    /// the frame used for matching, and asks Ghostty for a viewport and a frame.
    private func placeFrameAgain(visible: Range<Int>) {
        let reportCovers = TerminalBlankWatch.covers(presentedTop: scrollbar.offset, surfaceRows: surfaceRows, visibleTop: visible.lowerBound,
                                                     visibleBottom: visible.upperBound, documentRows: originRow..<(document?.endRow ?? Int.max))
        steadyViewport = nil
        presentedRows = nil
        if reportCovers {
            place(atRow: scrollbar.offset)
        } else {
            updateViewport(visibleMinY: scrollView.contentOffset.y, force: true)
        }
        if followAwaitsPresent {
            forceScroll = true
            applyScroll()
            forceScroll = false
        }
        surface.setNeedsTerminalDraw()
    }

    private func place(atRow top: Int) {
        presentedTop = top
        let origin = CGPoint(x: Self.sidePadding, y: CGFloat(presentedTop - originRow) * cell.height)
        if surface.frame.origin != origin {
            UIView.performWithoutAnimation { surface.frame.origin = origin }
        }
    }


    private func applyMode(tui: Bool) {
        presentedRows = nil
        steadyViewport = nil
        // Moving the surface to another superview resigns first responder:
        // typing into vim, then `:q`, used to drop the keyboard's input on the
        // floor (the composer still said "Typing into terminal").
        let hadFocus = surface.isFirstResponder
        defer {
            if hadFocus, !surface.isFirstResponder { surface.becomeFirstResponder() }
        }
        if tui {
            selection.clear()
            tuiSizing.tuiStarted()
            scrollView.isScrollEnabled = false
            scrollView.topEdgeEffect.style = .hard
            placesFromReport = false
            statusScrim.isHidden = true
            tuiClip.isHidden = false
            tuiHost.addSubview(surface)
            surface.frame = CGRect(x: 0, y: 0, width: hostLayout.surfaceWidth, height: CGFloat(surfaceRows) * cell.height)
            tuiPanX = 0
            tuiRowShift = 0
            tuiHost.bringSubviewToFront(hostGridNote)
            applyTUIPlacement()
            viewportTracker.request(0)
            surface.scroll(toRow: 0)
            scrollButtonVisibility = JumpToBottomVisibility()
            setScrollButton(visible: false)
        } else {
            // The app's screen is gone: its selection and fling go with it.
            tuiSelection.clear()
            tuiScroll.stopMomentum()
            tuiSizing.tuiEnded()
            scrollView.isScrollEnabled = true
            scrollView.topEdgeEffect.style = .soft
            tuiClip.isHidden = true
            statusScrim.isHidden = false
            hostGridNote.isHidden = true
            scrollView.addSubview(surface)
            viewportTop = -1
            scroll.reset()
            placesFromReport = true
            refreshAfterTUI = true
            // Direct typing outlives the TUI only while the terminal keeps focus.
            if !hadFocus { model.directTyping = false }
            document = nil
            updateDocument()
            applyScroll()
        }
        surface.drawNow()
        // The TUI's rows follow the settled keyboard (R1-1); the shell's do not.
        view.setNeedsLayout()
    }

    // MARK: Scrolling

    /// The document's height changed under the page (output, a prune, a
    /// clear). While a shorter height clamps the offset, the scroll that
    /// UIKit reports is the content moving, not the finger or a fling: it
    /// never counts as a fling reaching the bottom (V5-2).
    private var contentShrinking = false
    private var lastDidScrollY: CGFloat = 0

    private func setContentHeight(_ height: CGFloat) {
        let shrinking = height < scrollView.contentSize.height
        if shrinking { contentShrinking = true }
        scrollView.contentSize = CGSize(width: contentWidth, height: height)
        if shrinking { contentShrinking = false }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        measured("did-scroll") { didScroll(scrollView) }
    }

    private func didScroll(_ scrollView: UIScrollView) {
        #if DEBUG
        let stepStart = CACurrentMediaTime()
        defer { scrollMeter.step(start: stepStart, end: CACurrentMediaTime(), active: scroll.isInteracting) }
        #endif
        updateBottomFade()
        guard !model.isTUI else { return }
        if scrollView.isTracking, !pinningDrag {
            dragPin.moved(fingerY: scrollView.panGestureRecognizer.location(in: view).y,
                          keyboardTop: keyboardDock.guide.layoutFrame.minY)
            // The keyboard now follows the finger: back on the prompt (M6).
            if dragPinsToComposer { scroll.keyboardDragPinned() }
        }
        if dragPinsToComposer, scrollView.isTracking, !pinningDrag,
           scrollView.panGestureRecognizer.translation(in: view).y > 0 {
            // Dismissing the keyboard: the prompt stays on the composer.
            let target = maxOffsetY
            if abs(scrollView.contentOffset.y - target) > 0.5 {
                pinningDrag = true
                scrollView.contentOffset.y = target
                pinningDrag = false
            }
            updateViewport(visibleMinY: scrollView.contentOffset.y)
            return
        }
        updateViewport(visibleMinY: scrollView.contentOffset.y)
        if !settingOffset { scroll.scrolled(offsetY: scrollView.contentOffset.y, bottomOffsetY: maxOffsetY) }
        // A fling that reaches the bottom follows from there: while output
        // streams the deceleration would otherwise run on against a growing
        // end and leave the page short of it. The fling keeps its rubber
        // band past the end (it used to be stopped dead here, so a fling into
        // the bottom had no bounce while a drag past it did): UIKit owns the
        // page until the deceleration ends (applyScroll leaves it alone),
        // then the end of the deceleration places the page at the end.
        // Only a fling moving toward newer rows reaches the bottom; a prune
        // shrinking the document under it does not (V5-2: logged in the same
        // millisecond as a prune, a fling up from the live bottom snapped
        // back to following).
        let movingDown = scrollView.contentOffset.y > lastDidScrollY + 0.01
        lastDidScrollY = scrollView.contentOffset.y
        if !settingOffset, !contentShrinking, movingDown, scroll.isInteracting, !scrollView.isTracking, scrollView.isDecelerating,
           scrollView.contentOffset.y >= maxOffsetY - 0.5 {
            #if DEBUG
            sizingLog.notice("scroll: a fling reached the bottom -> following (bounce kept)")
            #endif
            scroll.flingReachedBottom()
        }
        // The rubber band past the top of a short scrollback is not a scroll
        // away from the prompt (verify/jump-button.md).
        setScrollButton(visible: scrollButtonVisibility.update(
            offsetY: scrollView.contentOffset.y, minOffsetY: -scrollView.contentInset.top, maxOffsetY: maxOffsetY))
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        // A reader who already scrolled up keeps scrolling normally.
        // Pinned only once the touch reaches the keyboard (R3-1).
        dragPin.began(following: following, keyboardUp: model.keyboardVisible, isTUI: model.isTUI)
        // A finger owns the offset until it lifts (or the deceleration ends).
        scroll.began()
        restoredMark = nil
        placesFromReport = false
        // A finger owns the page: a move waiting for its frame is dropped
        // (the next one measures its own wait).
        followAwaitsPresent = false
        awaitStarted = nil
        fling?.stop()
        fling = nil
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        let pinned = dragPinsToComposer
        dragPin.ended()
        if pinned {
            // The keyboard drag ended on the prompt.
            scroll.jumpToBottom()
            applyScroll()
        } else if !decelerate {
            settleScroll()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        settleScroll()
    }

    /// The finger lifted (or the deceleration ended): follow within two rows
    /// of the bottom, else read here, anchored to the top row.
    /// DEBUG A/B (`-CmuxMobileLegacyInteraction`): full batches and measures during a
    /// gesture, as before the 2026-10-14 smoothness fix.
    #if DEBUG
    static let legacyInteraction = CommandLine.arguments.contains("-CmuxMobileLegacyInteraction")
    #else
    static let legacyInteraction = false
    #endif

    /// The document grew without a measure during a gesture (updateDocument).
    private var measureAfterGesture = false

    private func settleScroll() {
        #if DEBUG
        if scrollMeter.frames > 0 {
            sizingLog.notice("scroll pacing: \(self.scrollMeter.frames, privacy: .public) frames, longest \(String(format: "%.1f", self.scrollMeter.longestMs), privacy: .public) ms, \(self.scrollMeter.over17, privacy: .public) over 17 ms, longest main-thread step \(String(format: "%.1f", self.scrollMeter.longestStepMs), privacy: .public) ms")
        }
        scrollMeter = ScrollMeter()
        #endif
        guard !model.isTUI, cell.height > 0 else { return }
        scroll.settled(offsetY: scrollView.contentOffset.y, bottomOffsetY: maxOffsetY, layout: document, rowHeight: cell.height)
        if measureAfterGesture {
            measureAfterGesture = false
            outputSinceProbe = true
            updateDocument()
        }
        #if DEBUG
        sizingLog.notice("scroll: settled -> \(String(describing: self.scroll.state), privacy: .public) (offset \(Int(self.scrollView.contentOffset.y), privacy: .public), bottom \(Int(self.maxOffsetY), privacy: .public))")
        #endif
        applyScroll()
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        // No fling away from the prompt after a pinned dismissal.
        if dragPinsToComposer { targetContentOffset.pointee = scrollView.contentOffset }
    }

    private func setScrollButton(visible requested: Bool) {
        // Following (a Jump to bottom tap, typing) hides the row at once,
        // while the page may still wait for the end's frame: the composer
        // shrinks before the page lands, not in the frames after (qa11 wt-fling-b).
        let visible = requested && !following
        guard model.isScrolledUp != visible else { return }
        model.isScrolledUp = visible
        // The composer shows its Jump to bottom row (`TerminalComposer`).
        // A hide is laid out now, in this transaction, so the frame that
        // shows the moved rows never still draws the row (round 11 N4: 4 of
        // 250 jumps drew it on the first moved frame; SwiftUI's own pass
        // came one frame later).
        guard !visible, let host = composerHost?.view else { return }
        UIView.performWithoutAnimation {
            host.setNeedsLayout()
            host.layoutIfNeeded()
        }
    }

    /// Jump to bottom: one tap lands at the live bottom and follows, whatever
    /// the page is doing (user report 2026-10-14: mid-fling the tap did
    /// nothing, since UIKit's deceleration kept the offset). The deceleration
    /// stops and a drag in progress is cancelled, so nothing else owns the page.
    func scrollToBottom(animated: Bool) {
        fling?.stop()
        fling = nil
        scroll.jumpToBottom()
        if scrollView.isTracking || scrollView.isDragging {
            let pan = scrollView.panGestureRecognizer
            pan.isEnabled = false
            pan.isEnabled = true
        }
        if scrollView.isDecelerating {
            settingOffset = true
            scrollView.setContentOffset(scrollView.contentOffset, animated: false)
            settingOffset = false
        }
        setScrollButton(visible: false)
        applyScroll()
        #if DEBUG
        sizingLog.notice("scroll: jump to bottom (decelerating \(self.scrollView.isDecelerating, privacy: .public), tracking \(self.scrollView.isTracking, privacy: .public)) -> offset \(Int(self.scrollView.contentOffset.y), privacy: .public) of \(Int(self.maxOffsetY), privacy: .public)")
        #endif
    }

    /// DEBUG demo: a decelerating fling with UIScrollView's normal rate, driven
    /// per display frame through the same delegate path as a finger fling.
    func fling(velocity: CGFloat) {
        placesFromReport = false
        fling?.stop()
        let animator = FlingAnimator(scrollView: scrollView, velocity: velocity, minY: -scrollView.contentInset.top, maxY: maxOffsetY)
        scroll.began()
        animator.onEnd = { [weak self] in
            self?.fling = nil
            self?.settleScroll()
        }
        fling = animator
        animator.start()
    }

    // MARK: Keyboard

    @objc private func tuiTapped(_ tap: UITapGestureRecognizer) {
        // A tap makes this phone the active device (Prefer the active device).
        model.session.noteInteraction()
        // A tap that ends a selection only ends it, as in the shell.
        if selection.selection == nil, tuiSelection.selection == nil, model.isTUI, surface.superview === tuiHost {
            surface.click(at: tap.location(in: surface))
        }
        terminalTapped()
    }

    @objc private func terminalTapped() {
        model.session.noteInteraction()
        // A tap outside the menu ends a selection, like iOS text.
        if selection.selection != nil || tuiSelection.selection != nil {
            selection.clear()
            tuiSelection.clear()
            return
        }
        // A tap brings back what Hide Toolbar took away (classic). An open
        // composer gets the focus back, so the next compose key tap reads it
        // as focused and its draft is never closed by surprise.
        if model.chromeHidden {
            model.setChromeHidden(false)
            if model.composerPresented {
                model.focusComposer()
                return
            }
        }
        focusTerminal()
    }

    private func installSelection() {
        selection.isEnabled = { [weak self] in
            guard let self else { return false }
            return !self.model.isTUI && self.document != nil && self.cell.height > 0
        }
        selection.columns = { [weak self] in max(1, self?.surface.grid.columns ?? 1) }
        selection.documentRows = { [weak self] in
            guard let document = self?.document else { return 0..<0 }
            return document.originRow..<document.endRow
        }
        selection.cellAt = { [weak self] point in
            guard let self, let document, cell.height > 0, cell.width > 0 else { return nil }
            let padding = surface.gridPadding
            // Within the document and the rows the surface holds (a handle
            // stops at the edge of the rendered rows).
            let top = max(document.originRow, scrollbar.offset)
            let bottom = min(document.endRow, scrollbar.offset + surface.grid.rows) - 1
            guard bottom >= top else { return nil }
            let row = min(max(top, document.row(atContentY: point.y - padding.y, cellHeight: cell.height)), bottom)
            let column = Int(floor((point.x - Self.sidePadding - padding.x) / cell.width))
            return TerminalCellPoint(row: row, column: min(max(0, column), max(0, surface.grid.columns - 1)))
        }
        selection.rectFor = { [weak self] point in
            guard let self, let document else { return .zero }
            let padding = surface.gridPadding
            return CGRect(x: Self.sidePadding + padding.x + CGFloat(point.column) * cell.width,
                          y: document.contentY(ofRow: point.row, cellHeight: cell.height) + padding.y,
                          width: cell.width, height: cell.height)
        }
        // Rows go to Ghostty as viewport rows (absolute row - the viewport's
        // top): the rows the surface holds, the visible ones and the margins.
        selection.rowText = { [weak self] row in
            guard let self else { return nil }
            return rowReader.text(TerminalAbsoluteRow(row))
        }
        selection.text = { [weak self] start, end in
            guard let self, let document else { return nil }
            let columns = max(1, surface.grid.columns)
            // Select All: the whole screen, scrollback included.
            if start == TerminalCellPoint(row: document.originRow, column: 0),
               end == TerminalCellPoint(row: document.endRow - 1, column: columns - 1) {
                return surface.screenText()
            }
            let top = scrollbar.offset, last = surface.grid.rows - 1
            // Rows outside the ones the surface holds (a selection the edge
            // autoscroll carried across the scrollback): Ghostty clamps an
            // exact point to its grid, so read the whole screen once (G-14).
            if start.row < top || end.row > top + last {
                return surface.screenRows()?.text(from: start, to: end)
            }
            let from = TerminalCellPoint(row: min(max(0, start.row - top), last), column: start.row < top ? 0 : start.column)
            let to = TerminalCellPoint(row: min(max(0, end.row - top), last), column: end.row - top > last ? columns - 1 : end.column)
            return surface.viewportText(from: from, to: to)
        }
        selection.visibleBand = { [weak self] in
            guard let self else { return 0...0 }
            let top = scrollView.adjustedContentInset.top
            return top...max(top, scrollView.bounds.height - scrollView.adjustedContentInset.bottom)
        }
        selection.offsetRange = { [weak self] in
            guard let self else { return 0...0 }
            let lower = -scrollView.contentInset.top
            return lower...max(lower, maxOffsetY)
        }
        // The page reads while the selection scrolls it, like a finger drag.
        selection.autoscrollBegan = { [weak self] in
            guard let self else { return }
            fling?.stop()
            fling = nil
            placesFromReport = false
            restoredMark = nil
            scroll.began()
        }
        selection.autoscrollEnded = { [weak self] in self?.settleScroll() }
        selection.install(in: scrollView)
        if let press = selection.longPress {
            press.addTarget(self, action: #selector(selectionPressChanged(_:)))
        }
        installTUISelection()
    }

    /// The alternate screen's selection: viewport rows in the TUI host, the
    /// text read from the surface's viewport (no scrollback, no autoscroll).
    private func installTUISelection() {
        let geometry = { [weak self] () -> TerminalTUISelectionGeometry in
            guard let self else { return TerminalTUISelectionGeometry(cellSize: .zero, padding: .zero, rows: 0, columns: 0) }
            let padding = surface.gridPadding
            return TerminalTUISelectionGeometry(cellSize: CGSize(width: cell.width, height: cell.height),
                                                padding: CGPoint(x: padding.x - tuiPanX, y: padding.y - CGFloat(tuiRowShift) * cell.height),
                                                rows: surface.grid.rows, columns: surface.grid.columns)
        }
        tuiSelection.isEnabled = { [weak self] in
            guard let self else { return false }
            return model.isTUI && cell.height > 0 && surface.superview === tuiHost
        }
        tuiSelection.columns = { [weak self] in max(1, self?.surface.grid.columns ?? 1) }
        tuiSelection.documentRows = { [weak self] in 0..<max(0, self?.surface.grid.rows ?? 0) }
        tuiSelection.cellAt = { geometry().cell(at: $0) }
        tuiSelection.rectFor = { geometry().rect(for: $0) }
        tuiSelection.rowText = { [weak self] row in
            guard let self else { return nil }
            let last = max(0, surface.grid.columns - 1)
            return surface.viewportText(from: TerminalCellPoint(row: row, column: 0), to: TerminalCellPoint(row: row, column: last))
        }
        tuiSelection.text = { [weak self] start, end in self?.surface.viewportText(from: start, to: end) }
        tuiSelection.install(in: tuiHost)
    }

    /// The alternate screen's drag: the app scrolls, the page stays pinned.
    private func installTUIScroll() {
        tuiScroll.isEnabled = { [weak self] in
            guard let self else { return false }
            return model.isTUI && surface.superview === tuiHost
        }
        tuiScroll.selectionOwns = { [weak self] touch in
            guard let self else { return false }
            if tuiSelection.isPressing { return true }
            return touch.map { tuiSelection.ownsTouch($0) } ?? false
        }
        // The rows move under a selection: it would point at other text.
        tuiScroll.dragBegan = { [weak self] in self?.tuiSelection.clear() }
        tuiScroll.install(in: tuiClip, surface: surface, tap: tuiTap)
    }

    /// While a long press selects, the page does not scroll under the finger.
    @objc private func selectionPressChanged(_ press: UILongPressGestureRecognizer) {
        switch press.state {
        case .began:
            scrollView.panGestureRecognizer.isEnabled = false
            scrollView.panGestureRecognizer.isEnabled = true
            scrollView.isScrollEnabled = false
        case .ended, .cancelled, .failed:
            scrollView.isScrollEnabled = true
        default:
            break
        }
    }

    func focusTerminal() {
        model.directTyping = true
        surface.becomeFirstResponder()
    }

    func hideKeyboard() {
        view.window?.endEditing(true)
    }

    @objc private func keyboardWillShow(_ note: Notification) {
        let notified = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .zero
        // In this app's points (an iPhone app on an iPad gets the iPad's keyboard in iPad points).
        let frame = keyboardDock.keyboardFrame(notified: notified, showing: true)
        let screen = view.window?.screen.bounds ?? UIScreen.main.bounds
        dock.keyboardWillShow(visibleHeight: max(0, screen.intersection(frame).height))
        setKeyBar(visible: dock.softKeyboard == .shown, note: note)
    }

    @objc private func keyboardWillHide(_ note: Notification) {
        dock.keyboardWillHide()
        setKeyBar(visible: false, note: note)
    }

    @objc private func keyboardDidHide() {
        dock.keyboardDidHide()
        keyboardDidChange()
    }

    @objc private func keyboardDidChange() {
        view.setNeedsLayout()
        view.layoutIfNeeded()
        // The keyboard settled: a TUI gets the rows above the composer now,
        // one resize (R1-1).
        tuiSizing.keyboardSettled(stackTop: bottomStack.frame.minY + composerGrowth, restingStackTop: restingStackTop, isTUI: model.isTUI)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        // The page changed without output (the keyboard came or went): the
        // saved frame for the next cold launch follows (R2-5).
        model.saveFrameSoon()
        updateViewport(visibleMinY: scrollView.contentOffset.y)
    }

    /// Keyboard state for the toolbar icon and the input target; layout
    /// follows the keyboard layout guide on its own.
    private func setKeyBar(visible: Bool, note: Notification) {
        guard model.keyboardVisible != visible else { return }
        model.keyboardVisible = visible
    }
}

/// The row shift's state, owned by the surface's output queue: every
/// `filter` call runs there, in feed order.
/// A still of the page taken on the main thread (`TerminalViewController.capture`)
/// and composed here, on any thread: the terminal background, the presented
/// frame's rows clipped to the page's rows area, and the cursor's cell with
/// the cursor hidden and its glyph kept (`TerminalCursorErase`). No chrome
/// (`TerminalStillPlan`).
struct TerminalPageCapture: @unchecked Sendable {
    let bounds: CGRect
    let scale: CGFloat
    var surface: TerminalPresentedCopy?
    /// The rows rendered on the main thread when the copy failed.
    var fallback: CGImage?
    let surfaceClip: CGRect
    var surfaceFrame: CGRect
    let cursor: CGRect?
    /// The terminal's background (`CmuxMobileGhosttyApp.background`).
    let background: UIColor

    func render() -> UIImage? {
        let width = Int((bounds.width * scale).rounded()), height = Int((bounds.height * scale).rounded())
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { return nil }
        // UIKit's coordinates (top-left origin, points): memory row 0 is the top.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        UIGraphicsPushContext(context)
        background.setFill()
        UIRectFill(bounds)
        if let image = surface?.makeImage() ?? fallback, !surfaceFrame.isNull, !surfaceClip.isEmpty {
            context.saveGState()
            context.clip(to: surfaceClip)
            UIImage(cgImage: image).draw(in: surfaceFrame)
            context.restoreGState()
        }
        UIGraphicsPopContext()
        if let cursor, let data = context.data {
            let pixels = CGRect(x: cursor.minX * scale, y: cursor.minY * scale, width: cursor.width * scale, height: cursor.height * scale)
                .intersection(surfaceClip.applying(CGAffineTransform(scaleX: scale, y: scale)))
                .integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
            if !pixels.isNull, !pixels.isEmpty {
                var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                background.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                TerminalCursorErase.erase(pixels: data.assumingMemoryBound(to: UInt8.self), bytesPerRow: context.bytesPerRow,
                                          rect: .init(x: Int(pixels.minX), y: Int(pixels.minY), width: Int(pixels.width), height: Int(pixels.height)),
                                          background: (UInt8(max(0, min(255, red * 255)).rounded()), UInt8(max(0, min(255, green * 255)).rounded()),
                                                       UInt8(max(0, min(255, blue * 255)).rounded())),
                                          bounds: (width, height))
            }
        }
        guard let image = context.makeImage() else { return nil }
        return UIImage(cgImage: image, scale: scale, orientation: .up)
    }
}

final class RowShiftBox: @unchecked Sendable {
    private var shift = TerminalRowShift()

    func filter(_ data: Data, offset: Int, remoteRows: Int) -> Data {
        shift.filter(data, offset: offset, remoteRows: remoteRows)
    }
}

/// A display link target that does not retain the controller. Once its
/// owner is gone the link stops itself (round 11 A3: a controller freed
/// while its follow fallback waited left that link firing forever).
@MainActor
final class DisplayLinkProxy: NSObject {
    private weak var owner: AnyObject?
    private let action: @MainActor () -> Void

    init(owner: AnyObject, _ action: @escaping @MainActor () -> Void) {
        self.owner = owner
        self.action = action
    }

    @objc func step(_ link: CADisplayLink) {
        guard owner != nil else { return link.invalidate() }
        action()
    }
}

/// A view whose layer is a gradient.
final class GradientView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    var gradient: CAGradientLayer { layer as! CAGradientLayer }
}

/// Who owns the chrome around the terminal (see `TerminalViewController`).
public enum TerminalChrome: Sendable {
    /// `TerminalScreen` in a navigation stack: its own toolbar and the safe area.
    case standalone
    /// A workspace tab: CmuxTabsKit's status bar area and floating toolbar.
    case embedded
}

// MARK: The Mac's grid when it is not the phone's

/// PROTOCOL.md "Terminal sizing policy", "A grid larger than the phone":
/// the mirror takes the Mac's columns (never rewrapped at the phone's width),
/// the page pans sideways when it is wider, and a full-screen app is pinned
/// to the top and letterboxed (or shifted to keep its cursor row) when its
/// rows differ. The phone's claim stays its own grid (`measuredGrid`).
extension TerminalViewController: @MainActor UIGestureRecognizerDelegate {
    var hostLayout: TerminalHostGridLayout {
        let remoteColumns = appliedHostColumns ?? model.session.remoteColumns
        return TerminalHostGridLayout(viewportWidth: view.bounds.width - 2 * Self.sidePadding, cell: cell,
                                      scale: view.window?.screen.scale ?? surface.renderScale, hostColumns: remoteColumns,
                                      hostRows: remoteColumns == nil ? nil : appliedHostRows ?? model.session.remoteRows,
                                      visibleRows: tuiRows)
    }

    /// The page's scrollable width: the mirror plus its side padding.
    var contentWidth: CGFloat {
        max(view.bounds.width, hostLayout.surfaceWidth + 2 * Self.sidePadding)
    }

    func applyContentWidth() {
        let width = contentWidth
        if scrollView.contentSize.width != width {
            scrollView.contentSize.width = width
        }
        let maxX = max(0, width - view.bounds.width)
        if scrollView.contentOffset.x > maxX || scrollView.contentOffset.x < 0 {
            scrollView.contentOffset.x = min(max(0, scrollView.contentOffset.x), maxX)
        }
        scrollView.isDirectionalLockEnabled = true
        scrollView.showsHorizontalScrollIndicator = maxX > 0
    }

    /// Before a batch is fed: the Mac's columns changed (`vt-state`,
    /// `resized`), so the mirror takes them now, ahead of the bytes drawn
    /// for them (its replay follows a reset).
    func syncHostGrid() {
        guard cell.width > 0, view.bounds.width > 0 else { return }
        if hostLayout.surfaceWidth != mirrorWidth {
            sizingLog.notice("mirror columns follow the Mac: \(self.hostLayout.columns, privacy: .public) (phone \(self.hostLayout.phoneColumns, privacy: .public), capped \(self.hostLayout.isCapped, privacy: .public))")
            view.setNeedsLayout()
            view.layoutIfNeeded()
        }
    }

    /// Typing pans just far enough to show the cursor's column.
    func followCursorColumn() {
        let layout = hostLayout
        guard layout.maxPanX > 0, cell.width > 0, let cursor = surface.visibleCursorCell else { return }
        let column = Int(floor((cursor.minX - surface.gridPadding.x) / cell.width))
        if model.isTUI {
            let pan = layout.pan(toShowColumn: column, from: tuiPanX)
            if pan != tuiPanX { tuiPanX = pan; applyTUIPlacement() }
        } else {
            let pan = layout.pan(toShowColumn: column, from: scrollView.contentOffset.x)
            if pan != scrollView.contentOffset.x { scrollView.contentOffset.x = pan }
        }
    }

    /// The full-screen app's surface in its host: panned, shifted to keep
    /// the cursor row, and the letterbox note under a shorter grid.
    func applyTUIPlacement() {
        guard model.isTUI, surface.superview === tuiHost, cell.height > 0 else {
            hostGridNote.isHidden = true
            return
        }
        let layout = hostLayout
        tuiPanX = layout.clampPan(tuiPanX)
        tuiRowShift = layout.rowShift(keeping: surface.cursorViewportRow, from: tuiRowShift)
        let origin = CGPoint(x: -tuiPanX, y: -CGFloat(tuiRowShift) * cell.height)
        if surface.frame.origin != origin {
            UIView.performWithoutAnimation { surface.frame.origin = origin }
        }
        if let box = layout.letterbox, let note = layout.note(owner: hostGridOwner) {
            hostGridNote.text = note
            hostGridNote.isHidden = false
            let height = ceil(hostGridNote.font.lineHeight)
            hostGridNote.frame = CGRect(x: 0, y: box.top + min(8, max(0, box.height - height) / 2),
                                        width: tuiHost.bounds.width, height: height)
            tuiHost.bringSubviewToFront(hostGridNote)
        } else {
            hostGridNote.isHidden = true
        }
    }

    @objc func tuiPanned(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            tuiPanStartX = tuiPanX
            fallthrough
        case .changed, .ended:
            tuiPanX = hostLayout.clampPan(tuiPanStartX - pan.translation(in: tuiClip).x)
            applyTUIPlacement()
        default:
            break
        }
    }

    /// The sideways pan of a full-screen app wider than the phone: a drag
    /// that is more horizontal than vertical (the app's own drag scrolls it).
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === tuiHorizontalPan, let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        guard model.isTUI, hostLayout.maxPanX > 0 else { return false }
        let moved = pan.translation(in: pan.view)
        let motion = moved == .zero ? pan.velocity(in: pan.view) : moved
        return abs(motion.x) > abs(motion.y)
    }
}

final class TerminalScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool { true }
}

/// Decelerates like UIScrollView (rate 0.998 per millisecond) on the display link.
@MainActor
final class FlingAnimator {
    private weak var scrollView: UIScrollView?
    private var velocity: CGFloat
    private let minY: CGFloat
    private let maxY: CGFloat
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    var onEnd: (() -> Void)?

    init(scrollView: UIScrollView, velocity: CGFloat, minY: CGFloat, maxY: CGFloat) {
        self.scrollView = scrollView
        self.velocity = velocity
        self.minY = minY
        self.maxY = maxY
    }

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = .terminal
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        onEnd?()
    }

    /// DEBUG pacing: display frames seen, frames that came later than 1.5
    /// display intervals (a hitch), the longest interval, and the main-thread
    /// time spent per step.
    static var pacing = (frames: 0, hitches: 0, longestMs: 0.0, stepMs: 0.0)
    private var previousTimestamp: CFTimeInterval = 0

    @objc private func step(_ link: CADisplayLink) {
        let began = CACurrentMediaTime()
        defer { Self.pacing.stepMs = max(Self.pacing.stepMs, (CACurrentMediaTime() - began) * 1000) }
        if previousTimestamp > 0 {
            let interval = link.timestamp - previousTimestamp
            let expected = link.targetTimestamp - link.timestamp
            Self.pacing.frames += 1
            Self.pacing.longestMs = max(Self.pacing.longestMs, interval * 1000)
            if expected > 0, interval > expected * 1.5 { Self.pacing.hitches += 1 }
        }
        previousTimestamp = link.timestamp
        guard let scrollView else { return stop() }
        if last == 0 { last = link.timestamp; return }
        let dt = link.targetTimestamp - last
        last = link.targetTimestamp
        velocity *= pow(0.998, dt * 1000)
        var y = scrollView.contentOffset.y + velocity * dt
        if y <= minY || y >= maxY {
            y = min(max(y, minY), maxY)
            velocity = 0
        }
        scrollView.contentOffset.y = y
        if abs(velocity) < 8 { stop() }
    }
}
#endif
