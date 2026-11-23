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
    /// The app's first rows pinned above the keyboard-clipped body
    /// (`TerminalGridSizing.keyboardPlacement`): the surface's presented
    /// frame again, cropped to those rows. Not the surface: it draws nothing.
    let tuiHeader = UIView()
    private let tuiHeaderRule = CALayer()
    /// Rows `tuiHeader` shows now (0: hidden).
    private(set) var tuiHeaderRows = 0
    /// Clips the area's height (`tuiHost`): rows the surface shifts above it
    /// (the cursor row kept on screen while a taller grid is fed behind the
    /// held still) never show in the sub-row band over row 1. As wide as
    /// the page's clip, so a panned or wider grid reaches the side padding.
    private let tuiAreaClip = UIView()
    private let bottomStack = UIView()
    private let bottomBacking = UIView()
    /// 24 pt fade above the composer card, shown only while rows are scrolled
    /// under it, so the row the card's edge cuts reads as "more below" (R2-6).
    private let bottomFade = GradientView()
    /// The last frame, held over the surface while a resize's mirror reset
    /// and replay are drawn, so the page never shows a black frame (R2-3).
    private var freezeView: UIView?
    /// The page as it was when the app left the foreground with this phone's
    /// grid on the Mac (`appActiveChanged`).
    private var backgroundStill: UIView?
    /// The held frame waits for the mirror reset of the reclaim's resize:
    /// output before it is the Mac's wider grid, never shown.
    private var holdAwaitsReset = false
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
    /// The Jump to bottom row, the stack's top row (CMUX-10).
    private var jumpRowHost: UIHostingController<TerminalJumpToBottomRow>!
    private var tuiHeight: NSLayoutConstraint!
    /// The terminal's background from the area's last row down to the
    /// composer: while the keyboard hides, the gap that opens below the old
    /// (shorter) grid shows nothing live or stale (the surface reaches below
    /// the area).
    private let tuiBelowCover = UIView()

    /// Rows of the local grid: the screen plus the largest keyboard, so the
    /// surface covers the old and new visible ranges during a keyboard animation.
    private var surfaceRows = 0
    /// Rows a TUI gets: between the toolbar and the composer, keyboard down.
    /// The soft keyboard never changes them (`TerminalGridSizing`).
    private var tuiRows = 0
    /// How far the TUI grid is moved down while the keyboard covers its
    /// bottom, so the cursor's row stays on screen (`TerminalGridSizing.keyboardLift`).
    private var tuiKeyboardLift: CGFloat = 0
    private var gridColumns = 0
    private var cell = CGSize.zero
    /// The Mac's grid when it is not the phone's (PROTOCOL.md "Terminal
    /// sizing policy"): the mirror takes its columns, the page pans sideways
    /// and a full-screen app is letterboxed or shifted (`TerminalHostGridLayout`).
    private var tuiPanX: CGFloat = 0
    private var tuiRowShift = 0
    /// The mirror width the last layout gave the surface, for `syncHostGrid`.
    private var mirrorWidth: CGFloat = 0
    /// The Mac's grid when it differs from the phone's (docs/shared-terminal-sizing.md
    /// "Showing the bounds"): "30×12 · set by Rig Mac" in the letterbox below
    /// a shorter grid, on the primary screen and in a full-screen app, or the
    /// compact "120×40" in the terminal area's top-trailing corner when the
    /// grid fills it. In the page's view, over the rows and under the dock.
    private let hostGridNote = UILabel()
    /// Where `hostGridNote` goes (`applyHostGridNote`); `positionHostGridNote`
    /// places it from this without building any text.
    private var hostGridNoteSpot = HostGridNoteSpot.none
    /// The Mac's rows the last layout used: a rows-only change lays out again (`syncHostGrid`).
    private var laidOutHostRows: Int?
    /// The primary screen shows a shorter Mac grid whole, pinned to the top
    /// (`pinsHostGrid`), as of the last layout: the document ends at its last
    /// row and starts no lower than its first.
    private var documentPinsHostGrid = false
    /// The chip's size for its text at its font size (measured once per
    /// text and Dynamic Type size).
    private var hostGridChipSize: (text: String, pointSize: CGFloat, size: CGSize)?
    /// The phone's own grid as last sent to the Mac (`sendResize`), and the
    /// one before it while that send may still be on its way. The Mac's grid
    /// at either is the phone's own: no note and no pin, or the page would
    /// jump and blame another device for the phone's own resize in flight.
    private var sentGrid: TerminalResizeSettle.Size?
    private var sentGridBefore: TerminalResizeSettle.Size?
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
        didSet {
            guard hostGridOwner != oldValue else { return }
            // The Mac answered the phone's last resize (the owner changed).
            sentGridBefore = nil
            applyHostGridNote()
        }
    }
    /// The Mac's rows as of the bytes fed so far (`appliedHostRows`), else
    /// the session's: the row shift and the screen's top use the grid the
    /// bytes were sent for, not one parsed ahead of them.
    var feedHostRows: Int? { appliedHostRows ?? model.session.remoteRows }
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
    /// Find… over the rows (the system find bar), scrollback included.
    let finder = TerminalFindController()
    /// Copy Mode (the Mac's Toggle Copy Mode): vi keys over the rows, Select Text… by touch.
    let copyMode = TerminalCopyModeController()
    /// The whole screen's rows, read once per scrollbar state while Copy Mode walks rows
    /// Ghostty cannot address one at a time (deep scrollback).
    private var copyModeRows: (key: [Int], rows: [String])?
    /// The shell's tap, and whether its touch landed on a moving page (that tap only
    /// stops the page, as in UIKit; it never opens the link under it).
    private weak var shellTap: UITapGestureRecognizer?
    private var tapStoppedScroll = false
    /// A vertical drag in a full-screen app scrolls the app (T-SCROLL-12).
    private let tuiScroll = TerminalTUIScrollController()
    /// Every pan's frame times, to the Mac (`phone-frames`), in every build.
    private lazy var panFrames: TerminalPanFrameRecorder = {
        let recorder = TerminalPanFrameRecorder()
        recorder.onPan = { [weak self] pan in
            guard let self else { return }
            model.session.reportScrollFrames(pan)
        }
        return recorder
    }()
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
    /// Jump to bottom's animated scroll, while it runs (CMUX-10).
    private var glide: BottomGlide?
    /// What the dock shows (key row, composer) and the soft keyboard's state.
    private var dock = TerminalDockVisibility()
    /// The old grid's rows, kept on the composer until the Mac's replay at
    /// the page's new rows is in (`TerminalTUIGridHold`). The soft keyboard
    /// never changes the rows (`TerminalGridSizing`); a chrome change does.
    private var tuiGridHold = TerminalTUIGridHold()
    private var tuiGridHoldExpiry: Task<Void, Never>?
    private var keyboardMovement = 0
    /// The Mac's redraw at fewer rows that waits for the keyboard to stop
    /// (`TerminalKeyboardReplayHold`).
    private var replayHold = TerminalKeyboardReplayHold()
    /// The replay at a new grid is parsed while the held frame is up: the
    /// area takes its new rows in the same pass that drops the held frame
    /// (`unfreeze`), after Ghostty presented the new grid, so no frame shows
    /// the new grid in the old area or the still where the area was.
    private var areaSwapPending = false
    /// When the keyboard's current movement ends (its notified duration).
    private var keyboardMoveEnds: CFTimeInterval = 0
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
    #if DEBUG
    /// cmux#48951: wheel report -> Mac output -> present (`TerminalScrollBench`).
    let rttLog = TerminalScrollRTT()
    #endif
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
        guard TerminalFrameLog.isEnabled || flickerTrace != nil else { return body() }
        let state = TerminalFrameLog.signposter.beginInterval(name)
        let start = CACurrentMediaTime()
        measureDepth += 1
        defer {
            measureDepth -= 1
            // Nested work is already inside the outer interval's time.
            let elapsed = CACurrentMediaTime() - start
            frameLog.work("\(name)", elapsed, outermost: measureDepth == 0)
            flickerTrace?.work("\(name)", elapsed, outermost: measureDepth == 0)
            TerminalFrameLog.signposter.endInterval(name, state)
        }
        return body()
    }
    private var measureDepth = 0
    #else
    private func measured<T>(_ name: StaticString, _ body: () -> T) -> T { body() }
    #endif

    /// The launch marks' first typed key and its echo on screen (`LaunchMarks`).
    private var firstEcho = TerminalFirstEcho()
    #if DEBUG
    /// Every typed key's echo (`InputLatencyTrace`, `terminal_key_echo`): one key
    /// in flight at a time, given up after 2 s (a key that echoes nothing).
    private var echoMeter = TerminalFirstEcho()
    private var echoStart: CFTimeInterval = 0
    #endif

    #if DEBUG
    /// Rig echo probe and text export (`-CmuxMobileTermProbe`, G-08/G-09).
    private lazy var devProbe: TerminalDevProbe? = TerminalDevProbe.isEnabled
        ? TerminalDevProbe(title: { [weak self] in self?.model.title ?? "" }, text: { [weak self] in self?.surface.screenRows()?.logicalText })
        : nil
    /// `-CmuxMobileTerminalFlickerTrace` (TerminalKeyboardToggleFlickerUITests).
    private var flickerTrace: TerminalFlickerTrace?
    /// Held stills taken, and the rows of the grid the latest one shows.
    private var freezeCount = 0
    private var freezeRows = 0
    /// The held still is committed (on screen), so a present under it shows nothing.
    private var heldCommitted = false
    #endif

    /// The cursor's distance from the last row when it was last seen.
    private var cursorRowsFromEnd: Int?
    /// Keeps the end from moving up while a TUI redraws below the cursor (termqa D2).
    private var endHold = TerminalEndHold()

    /// The scroll model is setting the offset (not a person).
    private var settingOffset = false
    /// The page's offset at the last scroll: which way the reader moves past
    /// a history window's end (``TerminalHistoryGap``).
    private var lastGapOffsetY: CGFloat?
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
        hiddenFeed?.cancel()
        followFallback?.invalidate()
        if outputPaused { model.session.setOutputPaused(false) }
    }

    /// The terminal's background: its Mac's terminal theme, else the app default.
    private var terminalBackground: UIColor { surface.hostTheme?.backgroundColor ?? CmuxMobileGhosttyApp.background }
    private var terminalInterfaceStyle: UIUserInterfaceStyle {
        surface.hostTheme?.interfaceStyle ?? CmuxMobileGhosttyApp.interfaceStyle
    }

    /// The Mac sent a new terminal theme: the page around the surface takes its background and look.
    private func terminalThemeDidChange(_ theme: CmuxMobileTerminalTheme) {
        model.hostTheme = theme
        guard isViewLoaded else { return }
        let base = theme.backgroundColor
        view.backgroundColor = base
        overrideUserInterfaceStyle = theme.interfaceStyle
        composerHost?.overrideUserInterfaceStyle = theme.interfaceStyle
        bottomBacking.backgroundColor = base
        tuiBelowCover.backgroundColor = base
        bottomFade.gradient.colors = [base.withAlphaComponent(0).cgColor, base.cgColor]
        if statusScrim.superview != nil {
            statusScrim.gradient.colors = [base.cgColor, base.cgColor, base.withAlphaComponent(0).cgColor]
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = terminalBackground
        // Chrome, glass and the keyboard follow the terminal theme (its Mac's look).
        overrideUserInterfaceStyle = terminalInterfaceStyle
        view.clipsToBounds = true
        // The terminal shows the terminal theme of the Mac its session runs on, live.
        surface.onHostTheme = { [weak self] theme in self?.terminalThemeDidChange(theme) }
        surface.themeMacID = model.hostMacID
        if let theme = surface.hostTheme { model.hostTheme = theme }

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
        tuiAreaClip.clipsToBounds = true
        tuiAreaClip.isUserInteractionEnabled = true
        tuiAreaClip.translatesAutoresizingMaskIntoConstraints = false
        tuiClip.addSubview(tuiAreaClip)
        tuiAreaClip.addSubview(tuiHost)
        tuiBelowCover.isUserInteractionEnabled = false
        tuiBelowCover.translatesAutoresizingMaskIntoConstraints = false
        tuiBelowCover.backgroundColor = terminalBackground
        tuiClip.addSubview(tuiBelowCover)
        view.addSubview(tuiClip)
        tuiClip.addGestureRecognizer(tuiHorizontalPan)
        // The top exception: the app's first rows, drawn from the surface's
        // own frame, over the area's top while the keyboard clips it.
        tuiHeader.isHidden = true
        tuiHeader.isUserInteractionEnabled = false
        tuiHeader.layer.contentsGravity = .resize
        tuiHeader.layer.masksToBounds = true
        tuiHeaderRule.backgroundColor = UIColor.separator.cgColor
        tuiHeader.layer.addSublayer(tuiHeaderRule)
        view.insertSubview(tuiHeader, aboveSubview: tuiClip)
        hostGridNote.font = UIFont.preferredFont(forTextStyle: .caption2)
        hostGridNote.adjustsFontForContentSizeCategory = true
        // A Dynamic Type change resizes the note's font: measure the chip and place the note again.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (screen: TerminalViewController, _: UITraitCollection) in
            screen.applyHostGridNote()
        }
        // The terminal's theme is dark in both appearances: the note's gray
        // is the dark one (the light one is near black on the grid's background).
        hostGridNote.textColor = UIColor.secondaryLabel.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        hostGridNote.lineBreakMode = .byTruncatingTail
        hostGridNote.isHidden = true
        hostGridNote.isUserInteractionEnabled = false
        hostGridNote.isAccessibilityElement = true
        hostGridNote.accessibilityTraits = .staticText
        hostGridNote.accessibilityIdentifier = "terminal.hostGridNote"
        hostGridNote.layer.cornerCurve = .continuous
        // Over the primary screen's rows and the TUI; the dock (added below) covers it.
        view.addSubview(hostGridNote)

        let keyBar = UIHostingController(rootView: TerminalKeyBar(model: model))
        let composer = UIHostingController(rootView: TerminalComposer(model: model))
        let jumpRow = UIHostingController(rootView: TerminalJumpToBottomRow(model: model))
        keyBar.safeAreaRegions = []
        composer.safeAreaRegions = []
        jumpRow.safeAreaRegions = []
        // The terminal is dark in both appearances; so are its key bar and
        // composer (in light mode inside a workspace they drew light glass
        // over the black grid).
        keyBar.overrideUserInterfaceStyle = .dark
        // The composer fills with the terminal theme's background (Leo,
        // 2026-11-22: "dont draw unnecessary attention by making it light"),
        // so its text and hairline take the theme's look, light or dark.
        composer.overrideUserInterfaceStyle = terminalInterfaceStyle
        jumpRow.overrideUserInterfaceStyle = .dark
        composer.sizingOptions = [.intrinsicContentSize]
        jumpRow.sizingOptions = [.intrinsicContentSize]
        bottomStack.addSubview(keyBarClip)
        for host in [keyBar as UIViewController, composer, jumpRow] {
            host.view.backgroundColor = .clear
            host.view.translatesAutoresizingMaskIntoConstraints = false
            addChild(host)
            (host === keyBar ? keyBarClip : bottomStack).addSubview(host.view)
            host.didMove(toParent: self)
        }
        keyBarHost = keyBar
        composerHost = composer
        jumpRowHost = jumpRow
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
        bottomBacking.backgroundColor = terminalBackground
        bottomBacking.isUserInteractionEnabled = false
        bottomBacking.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottomBacking)
        let base = terminalBackground
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
        // stack, top to bottom (classic cmux iOS): the Jump to bottom row (0 pt
        // unless scrolled up; its pill and 8 pt), the 28 pt key row, 8 pt, the
        // composer; Hide Toolbar folds both, closing the composer folds it. The
        // page's rows end at the stack's top, so above the Jump to bottom pill.
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
                let base = terminalBackground
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
            jumpRow.view.topAnchor.constraint(equalTo: bottomStack.topAnchor),
            jumpRow.view.leadingAnchor.constraint(equalTo: bottomStack.leadingAnchor),
            jumpRow.view.trailingAnchor.constraint(equalTo: bottomStack.trailingAnchor),
            // Empty, the row has no intrinsic height; this keeps it at 0 pt.
            prioritized(jumpRow.view.heightAnchor.constraint(equalToConstant: 0), .fittingSizeLevel),
            keyBarClip.topAnchor.constraint(equalTo: jumpRow.view.bottomAnchor),
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
            // Bottom-pinned: the grid's bottom rides the composer stack inside
            // the keyboard's animation; the keyboard clips its top instead of
            // resizing it (`TerminalGridSizing.keyboardPlacement`).
            tuiHost.bottomAnchor.constraint(equalTo: tuiClip.bottomAnchor),
            tuiHost.leadingAnchor.constraint(equalTo: tuiClip.leadingAnchor, constant: Self.sidePadding),
            tuiHost.trailingAnchor.constraint(equalTo: tuiClip.trailingAnchor, constant: -Self.sidePadding),
            tuiHeight,
            tuiAreaClip.topAnchor.constraint(equalTo: tuiHost.topAnchor),
            tuiAreaClip.bottomAnchor.constraint(equalTo: tuiHost.bottomAnchor),
            tuiAreaClip.leadingAnchor.constraint(equalTo: tuiClip.leadingAnchor),
            tuiAreaClip.trailingAnchor.constraint(equalTo: tuiClip.trailingAnchor),
            tuiBelowCover.topAnchor.constraint(equalTo: tuiHost.bottomAnchor),
            tuiBelowCover.leadingAnchor.constraint(equalTo: tuiClip.leadingAnchor),
            tuiBelowCover.trailingAnchor.constraint(equalTo: tuiClip.trailingAnchor),
            // As tall as the page, clipped by `tuiClip`: tied to the clip's
            // bottom, a host taller than the clip (a shell's keyboard-down
            // rows with the keyboard up) pushed the clip, and the composer
            // under it, down outside the keyboard's animation.
            tuiBelowCover.heightAnchor.constraint(equalTo: view.heightAnchor),

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

        let tap = UITapGestureRecognizer(target: self, action: #selector(shellTapped(_:)))
        tap.delegate = self
        shellTap = tap
        scrollView.addGestureRecognizer(tap)
        tuiClip.addGestureRecognizer(tuiTap)
        // The model may already have a closed or hidden composer (a page rebuilt for it).
        dockChanged()
        installSelection()
        installFind()
        installCopyMode()
        installTUIScroll()

        surface.configurePasteControlTarget()
        surface.onInput = { [weak self] data in
            #if DEBUG
            self?.devProbe?.sent(data)
            #endif
            guard let self else { return }
            // A refusal comes back as `.inputNotSent` from inside `send`.
            inputRefused = false
            // Only what the person typed, pressed or pasted is a key (Leo,
            // 2026-11-14: "all I did was navigate away and then it showed
            // this, but I didn't type anything"). A scroll's wheel reports, a
            // tap's click report, a key release and Ghostty's replies to
            // terminal queries go only while attached and never make the
            // "Keys typed while your Mac was unreachable" notice.
            if surface.isEncodingUserInput {
                model.session.send(data)
                // The launch marks' key: one the session took (not refused, not held for a
                // reattach), in the one terminal whose echo is then tracked (the marks are per process).
                if model.connectionState.isAttached, !inputRefused, !LaunchMarks.shared.has("terminal_key_sent"),
                   firstEcho.sent(data) {
                    LaunchMarks.shared.mark("terminal_key_sent")
                }
                #if DEBUG
                if InputLatencyTrace.isEnabled, model.connectionState.isAttached, !inputRefused {
                    let now = CACurrentMediaTime()
                    if echoMeter.step != .idle, now - echoStart > 2 { echoMeter = TerminalFirstEcho() }
                    if echoMeter.sent(data) { echoStart = now }
                }
                #endif
            } else {
                model.session.sendReply(data)
                // A scroll or a tap is still the person's: this phone is the active device.
                if surface.isPerformingInput { model.session.noteInteraction() }
            }
        }
        // Held for a reattach (or a first attach still coming) is not sent:
        // the echo may never come, so nothing is predicted for it.
        surface.inputGoesOut = { [weak self] in
            guard let self else { return false }
            return model.connectionState.isAttached && !inputRefused
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
        surface.onShownChange = { [weak self] shown in self?.pageShownChanged(shown) }
        surface.onPresent = { [weak self] in
            guard let self else { return }
            self.measured("present") { self.surfacePresented() }
            #if DEBUG
            self.rttLog.presented()
            #endif
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
        center.addObserver(self, selector: #selector(keyboardDidShow(_:)), name: UIResponder.keyboardDidShowNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardDidHide(_:)), name: UIResponder.keyboardDidHideNotification, object: nil)
        // A keyboard that went with no hide notification (while the app was in
        // the background) is forgotten by the tracker: settle as after a hide.
        keyboardTracker.subscribeToDrops(self) { [weak self] in self?.keyboardDropped() }
        #if DEBUG
        center.addObserver(self, selector: #selector(appBecameActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        if TerminalFlickerTrace.isRequested {
            flickerTrace = TerminalFlickerTrace(host: view) { [weak self] in self?.flickerSample() }
        }
        #endif
    }

    #if DEBUG
    /// Return probe (TerminalProjectionUITests): from the app becoming active
    /// to the first display frame that shows the terminal right.
    private var returnProbe: (link: CADisplayLink, start: CFTimeInterval)?

    @objc private func appBecameActive() {
        returnProbe?.link.invalidate()
        let link = CADisplayLink(target: self, selector: #selector(returnProbeTick(_:)))
        link.add(to: .main, forMode: .common)
        returnProbe = (link, CACurrentMediaTime())
    }

    @objc private func returnProbeTick(_ link: CADisplayLink) {
        guard let probe = returnProbe else { return link.invalidate() }
        let phoneWidth = model.isTUI || (appliedHostColumns ?? hostLayout.phoneColumns) == hostLayout.phoneColumns
        let right = phoneWidth && freezeView == nil && !replayGate.isReplaying && output.isEmpty && !feedInFlight
        let elapsed = link.timestamp - probe.start
        guard right || elapsed > 5 else { return }
        model.lastReturnMs = right ? Int((max(0, elapsed) * 1000).rounded()) : -2
        sizingLog.notice("return probe: first right frame after \(self.model.lastReturnMs, privacy: .public) ms")
        link.invalidate()
        returnProbe = nil
    }

    /// Keyboard probe (TerminalProjectionUITests): every display frame of a
    /// soft keyboard transition and half a second after it, whether the
    /// terminal is narrower than the phone and whether the cursor's row moved
    /// against the keyboard (down while it shows, up while it hides).
    private var keyboardProbe: (link: CADisplayLink, showing: Bool, lastY: CGFloat?, until: CFTimeInterval)?

    private func startKeyboardProbe(showing: Bool) {
        keyboardProbe?.link.invalidate()
        let link = CADisplayLink(target: self, selector: #selector(keyboardProbeTick(_:)))
        link.add(to: .main, forMode: .common)
        // The did-show or did-hide shortens this to half a second past it.
        keyboardProbe = (link, showing, nil, CACurrentMediaTime() + 2)
    }

    private func settleKeyboardProbe() {
        guard let probe = keyboardProbe else { return }
        keyboardProbe?.until = min(probe.until, CACurrentMediaTime() + 0.5)
    }

    @objc private func keyboardProbeTick(_ link: CADisplayLink) {
        guard var probe = keyboardProbe, probe.link === link else { return link.invalidate() }
        if !model.isTUI {
            let layout = hostLayout
            if layout.columns < layout.phoneColumns {
                model.narrowKeyboardFrames += 1
                sizingLog.notice("keyboard probe: \(layout.columns, privacy: .public) columns, narrower than the phone's \(layout.phoneColumns, privacy: .public)")
            }
            if let cursor = surface.visibleCursorCell {
                let y = surface.convert(cursor, to: view).minY
                if let last = probe.lastY, (probe.showing ? y - last : last - y) > 1 {
                    model.keyboardBounces += 1
                    sizingLog.notice("keyboard probe: cursor row moved \(Int(y - last), privacy: .public) pt against the keyboard (showing \(probe.showing, privacy: .public))")
                }
                probe.lastY = y
            }
        }
        if link.timestamp >= probe.until {
            link.invalidate()
            keyboardProbe = nil
        } else {
            keyboardProbe = probe
        }
    }

    /// The page as drawn this frame, for `TerminalFlickerTrace`.
    private func flickerSample() -> TerminalFlickerTrace.Sample? {
        guard cell.height > 0 else { return nil }
        // Sampled after UIKit's commit: a still up now is on screen.
        if freezeView != nil { heldCommitted = true }
        let probe = MobileKeyboardProbe()
        var sample = TerminalFlickerTrace.Sample(demo: model.demoNote, isTUI: model.isTUI, held: freezeView != nil,
                                                 stackTop: probe.onScreen(bottomStack, in: view).minY, resizes: model.ptyResizesSent,
                                                 surfaceSize: surface.bounds.size)
        if model.isTUI {
            let rows = appliedHostRows ?? model.session.remoteRows ?? tuiRows
            sample.gridTop = probe.onScreen(surface, in: view).minY + surface.gridPadding.y
            sample.gridRows = rows
            sample.pageRows = tuiRows
            sample.heldAreaRows = tuiGridHold.heldRows ?? 0
            sample.areaInset = tuiKeyboardLift
            sample.sentRows = claimedTUIRows ?? 0
            sample.coverTop = probe.onScreen(tuiBelowCover, in: view).minY
            sample.areaTop = probe.onScreen(tuiHost, in: view).minY
            sample.areaClips = tuiHost.clipsToBounds || tuiHost.superview?.clipsToBounds == true
            sample.heldRows = freezeRows
            sample.heldID = freezeCount
            sample.clipTop = probe.onScreen(tuiClip, in: view).minY
            sample.cellHeight = cell.height
            sample.noteShown = !hostGridNote.isHidden
            sample.nonBlankRows = surface.activeAreaText().map { TerminalHeldFrame.nonBlankRows(in: $0, limit: rows) } ?? 0
            if let held = freezeView {
                // The still itself (in its cover, for an area still).
                let still = held.superview === view ? held : (held.subviews.first ?? held)
                let drawn = probe.onScreen(still, in: view)
                sample.heldTop = drawn.minY
                sample.heldBottom = drawn.maxY
                sample.heldIsArea = held.superview !== view
            }
        } else {
            let frame = probe.onScreen(scrollView, in: view)
            let bounds = (scrollView.layer.presentation() ?? scrollView.layer).bounds
            sample.contentBottom = frame.minY + scrollView.contentSize.height - bounds.minY
            sample.legibleBlank = legibleRowsBlank
            sample.cellHeight = cell.height
            sample.offsetModel = scrollView.contentOffset.y
            sample.offsetDrawn = bounds.minY
            sample.insetBottom = scrollView.contentInset.bottom
            let drawn = probe.onScreen(surface, in: view)
            sample.surfaceTop = drawn.minY
            sample.surfaceBottom = drawn.maxY
            sample.following = following
            sample.legibleTop = frame.minY + scrollView.contentInset.top
            sample.contentHeight = scrollView.contentSize.height
        }
        return sample
    }
    #endif

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        registerEdgeEffectScrollView()
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        registerEdgeEffectScrollView()
        #if DEBUG
        frameLog.start()
        TerminalScrollBench.install(self)
        #endif
        startBlankWatch()
        // Back on screen (a tab switch, the grid): output that arrived while
        // the page was away was laid out against stale geometry. Recompute
        // the document and, when following, rest the last row above the
        // composer on the first frame (Codex QA F8).
        // The keyboard may have come or gone while the page was away; a
        // keyboard on record that nothing owns now is gone (no inset for it).
        keyboardTracker.dropKeyboardWithoutOwner()
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
           fling == nil, glide == nil, !dragPinsToComposer, !model.isTUI, cell.height > 0 {
            scroll.settled(offsetY: scrollView.contentOffset.y, bottomOffsetY: maxOffsetY, layout: document, rowHeight: cell.height)
            #if DEBUG
            sizingLog.notice("scroll: settled by applyScroll -> \(String(describing: self.scroll.state), privacy: .public)")
            #endif
        }
        // UIKit (or Jump to bottom's glide) is moving the page: leave it alone.
        if scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating, !dragPinsToComposer { return }
        if glide != nil { return }
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
                #if DEBUG
                if scroll.awaitsPlacement { TerminalHistoryWindowProbe.shared.note("I") }
                #endif
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
        #if DEBUG
        if scroll.awaitsPlacement { TerminalHistoryWindowProbe.shared.note("G") }
        #endif
        scroll.reachedTarget()
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

    /// No answer within `TerminalTUIGridHold.cap` (the Mac kept its grid):
    /// the area shows the page's rows.
    private func armGridHoldExpiry() {
        tuiGridHoldExpiry?.cancel()
        tuiGridHoldExpiry = nil
        guard tuiGridHold.heldRows != nil else { return }
        tuiGridHoldExpiry = Task { @MainActor [weak self] in
            try? await ContinuousClock().sleep(for: TerminalTUIGridHold.cap)
            guard let self, !Task.isCancelled, self.tuiGridHold.heldRows != nil else { return }
            sizingLog.notice("grid hold expired: no replay at \(self.tuiRows, privacy: .public) rows")
            if self.freezeView != nil, self.model.isTUI {
                // Under a held still: the area changes when the still goes.
                self.endGridHold(layout: false)
                self.areaSwapPending = true
            } else {
                self.endGridHold(layout: true)
            }
        }
    }

    /// The rows last sent for a full-screen app (the claim a replay answers).
    private var claimedTUIRows: Int?

    private func gridReplayed() {
        // The held frame is up: the area changes when it goes (`unfreeze`).
        if freezeView != nil, model.isTUI {
            areaSwapPending = true
            return
        }
        swapArea()
    }

    /// The area takes the rows of the replay just parsed (or keeps the
    /// replay's grid while the page's own claim is still on its way).
    private func swapArea() {
        areaSwapPending = false
        let held = tuiGridHold.heldRows
        let shown = appliedHostRows ?? model.session.remoteRows
        let pending = resizeSettle.pending?.rows == tuiRows || (claimedTUIRows == tuiRows && shown != tuiRows)
        tuiGridHold.replayed(rows: shown, page: tuiRows, claimPending: model.isTUI && pending)
        if tuiGridHold.heldRows == nil {
            tuiGridHoldExpiry?.cancel()
            tuiGridHoldExpiry = nil
        } else if tuiGridHold.heldRows != held {
            armGridHoldExpiry()
        }
        let areaHeight = CGFloat(tuiGridHold.rows(page: tuiRows)) * cell.height
        if tuiGridHold.heldRows != held || (cell.height > 0 && tuiHeight.constant != areaHeight) {
            relayoutTUIArea()
        }
    }

    /// The TUI area: the held grid's rows, else the page's, on the composer
    /// stack (bottom-pinned).
    private func applyTUIAreaHeight(cellHeight: CGFloat) {
        let areaHeight = CGFloat(tuiGridHold.rows(page: tuiRows)) * cellHeight
        if tuiHeight.constant != areaHeight { tuiHeight.constant = areaHeight }
    }

    /// The hold changed outside a layout pass: the area takes its height in
    /// this pass. Set from `layoutTerminal` (inside `viewDidLayoutSubviews`),
    /// the constraint only moved the area in the next display frame, one
    /// frame after the held frame went (the grid hung from the toolbar for a
    /// frame).
    private func relayoutTUIArea() {
        if cell.height > 0 { applyTUIAreaHeight(cellHeight: cell.height) }
        view.setNeedsLayout()
        view.layoutIfNeeded()
        // tuiHost is laid out by tuiClip, after the page's own pass (#42422).
        tuiClip.layoutIfNeeded()
    }

    /// Sizes sent for a full-screen app and not answered yet, oldest first.
    /// The Mac answers every resize, in order (a grid change, a mirror reset
    /// and a replay); while a newer one is out, an answer is for a size the
    /// page no longer wants. Only the newest answer is drawn: a toggle the
    /// person took back (show, then hide before the Mac answered) swaps the
    /// grid 0 times, a double toggle once.
    private var claimsInFlight: [(size: TerminalResizeSettle.Size, at: CFTimeInterval)] = []

    /// Claims older than a round trip's cap get no answer (the Mac kept its
    /// grid, or the link changed).
    private func pruneClaims() {
        let now = CACurrentMediaTime()
        let cap = TerminalTUIGridHold.capSeconds
        claimsInFlight.removeAll { now - $0.at > cap }
    }

    /// The Mac's grid `size` arrived: it answers the oldest claim of that
    /// size, and is stale when a newer claim is still out.
    private func answerIsStale(_ size: TerminalResizeSettle.Size) -> Bool {
        pruneClaims()
        guard model.isTUI, let index = claimsInFlight.firstIndex(where: { $0.size == size }) else { return false }
        claimsInFlight.removeFirst(index + 1)
        return !claimsInFlight.isEmpty
    }

    /// The newest answer is still out for a full-screen app: a held still
    /// stays up until it is drawn (an older answer fed meanwhile is never
    /// shown).
    private var newestAnswerAwaited: Bool {
        guard model.isTUI else { return false }
        pruneClaims()
        return !claimsInFlight.isEmpty
    }

    /// A stale answer waits at most a round trip's cap for the newest one.
    private func armStaleAnswerExpiry() {
        staleAnswerExpiry?.cancel()
        staleAnswerExpiry = Task { @MainActor [weak self] in
            try? await ContinuousClock().sleep(for: TerminalTUIGridHold.cap)
            guard let self, !Task.isCancelled, self.output.nextHostGridIsStale || !self.claimsInFlight.isEmpty else { return }
            sizingLog.notice("the newest answer did not come: queued answers go to the screen")
            self.claimsInFlight.removeAll()
            // Only the last answer queued is drawn: the replay gate counts
            // the replay after the last reset, and the older ones' resets
            // would end it early.
            self.output.keepLastStaleAnswer()
            self.output.clearStale()
            self.scheduleOutput()
            if self.freezeView != nil, self.model.isTUI, self.heldFrameMayGo() { self.unfreeze() }
        }
    }
    private var staleAnswerExpiry: Task<Void, Never>?

    private func endGridHold(layout: Bool) {
        tuiGridHoldExpiry?.cancel()
        tuiGridHoldExpiry = nil
        guard tuiGridHold.heldRows != nil else { return }
        tuiGridHold.release()
        guard layout else { return }
        relayoutTUIArea()
    }

    private func sendResize(_ size: TerminalResizeSettle.Size, why: String) {
        sizingLog.notice("resize \(size.columns, privacy: .public)x\(size.rows, privacy: .public) cause=\(why, privacy: .public)\(self.model.isTUI ? "-tui" : "", privacy: .public) attached=\(self.model.connectionState.isAttached, privacy: .public) (TUI \(self.model.isTUI, privacy: .public))")
        model.session.resize(columns: size.columns, rows: size.rows)
        model.ptyResizesSent += 1
        if size != sentGrid {
            sentGridBefore = sentGrid
            sentGrid = size
        }
        claimedTUIRows = size.rows
        if model.isTUI, why != "first" {
            // Answers still queued answer an older size now.
            pruneClaims()
            output.markGridsStale()
            claimsInFlight.append((size, CACurrentMediaTime()))
            // The Mac may keep its grid and not answer: the wait ends.
            armStaleAnswerExpiry()
        }
        // The answer to this claim is a round trip away from now.
        if tuiGridHold.heldRows != nil { armGridHoldExpiry() }
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

    /// The Jump to bottom row's SwiftUI height changed: the stack and the
    /// page's insets follow in this pass, like the composer card's.
    func jumpRowHeightChanged(_ height: CGFloat) {
        guard let host = jumpRowHost else { return }
        host.view.invalidateIntrinsicContentSize()
        host.view.setNeedsLayout()
        view.setNeedsLayout()
        view.layoutIfNeeded()
        updateBottomBacking()
        applyScroll()
    }

    private var jumpRowHeight: CGFloat { jumpRowHost?.view.bounds.height ?? 0 }

    /// The solid background under the stack shows while any row of it does:
    /// the key row, the composer, or the Jump to bottom pill (with Hide
    /// Toolbar on, the pill alone; without it the scrolled rows drew under the
    /// pill's glass, CMUX-10 review).
    private func updateBottomBacking() {
        bottomBacking.isHidden = !dock.showsKeyRow && !dock.showsComposer && jumpRowHeight == 0
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
                                          background: terminalBackground)
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
        panFrames.finish()
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
        updateBottomBacking()
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
                    // Interruptible: the key row takes taps while it fades in.
                    UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                        self.keyBarClip.alpha = 1
                    }
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
        measured("layout-terminal") { layoutTerminal() }
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
        return "sb=\(scrollbar.total)/\(scrollbar.offset)/\(scrollbar.visible) doc=\(originRow)+\(documentRows) top=\(viewportTop) rows=\(surfaceRows) tui=\(tuiRows) grid=\(grid.columns)x\(grid.rows) cell=\(cell) off=\(Int(scrollView.contentOffset.y)) size=\(Int(scrollView.contentSize.height)) inset=\(Int(scrollView.contentInset.top)),\(Int(scrollView.contentInset.bottom)) follow=\(following) cursor=\(surface.cursorViewportRow.map(String.init) ?? "-") draws=\(surface.draws) presents=\(surface.presents) presented=\(presentedTop) pacing(frames/hitches/longestMs/stepMs)=\(FlingAnimator.pacing.frames)/\(FlingAnimator.pacing.hitches)/\(String(format: "%.1f", FlingAnimator.pacing.longestMs))/\(String(format: "%.2f", FlingAnimator.pacing.stepMs)) kbguide=\(Int(keyboardDock.guide.layoutFrame.minY)) stack=\(Int(bottomStack.frame.minY))-\(Int(bottomStack.frame.maxY)) keybar=\(Int(keyBarClip.frame.minY))-\(Int(keyBarClip.frame.maxY)) view=\(Int(view.bounds.height)) safe=\(Int(view.safeAreaInsets.top)),\(Int(view.safeAreaInsets.bottom)) tuiclip=\(Int(tuiClip.frame.minY))-\(Int(tuiClip.frame.maxY)) tuihost=\(Int(tuiClip.frame.minY + tuiHost.frame.minY))+\(Int(tuiHost.frame.height)) surface.y=\(Int(surface.frame.minY)) shift=\(tuiRowShift) lift=\(Int(tuiKeyboardLift)) header=\(tuiHeaderRows)"
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
    /// What the output pump did: display frames it ran on, pump calls and
    /// batches handed to Ghostty. For tests and benches.
    private(set) var outputCounts = TerminalOutputPumpCounts()
    /// Session bytes queued and not yet handed to Ghostty.
    var outputPendingBytes: Int { output.pendingBytes }
    /// How often a page nobody can see hands its queued output to Ghostty.
    static let hiddenFeedInterval: TimeInterval = 1

    private func sessionEvent(_ event: TerminalSessionEvent) {
        switch event {
        case .connection, .exited, .alternateScreen(false):
            // A disconnect, a reattach, the process gone or the app off the
            // alternate screen: a keyboard hold ends now (its held frame, if
            // a reset waits behind it, is taken before the replay is fed).
            let leaving = event == .alternateScreen(false)
            apply(replayHold.arrived(event, isTUI: model.isTUI, heldRows: tuiGridHold.heldRows, pageRows: tuiRows).release, pageWide: leaving)
            // Nothing waits for an answer any more: a reattach replays at the
            // grid it has, an app off the alternate screen keeps no hold.
            claimsInFlight.removeAll()
            output.clearStale()
        default:
            break
        }
        switch event {
        case .output(let data):
            panFrames.output(data.count)
            let isReset = data == Self.mirrorReset
            if isReset {
                sizingLog.notice("mirror reset cause=session-reset (the session's replay follows)")
                holdAwaitsReset = false
                // The rows being read are rebuilt from the replay: a reader
                // goes back to their rows once it is in (V2-3,
                // TerminalReadingMark); otherwise to the prompt. A place
                // waiting for older rows is placed by this reset's replay.
                olderRowsAsked = false
                #if DEBUG
                let probeContext = probeResetContext()
                let probeWaiting = restorePending
                probeMarkMiss = "-"
                #endif
                markReadingPosition()
                #if DEBUG
                let outcome = probeWaiting ? "W" : (readingMark != nil ? "M" : "Z")
                TerminalHistoryWindowProbe.shared.note(Character(outcome))
                TerminalHistoryWindowProbe.shared.lastReset = "\(probeContext):\(outcome)\(outcome == "Z" ? probeMarkMiss : "")"
                // The first attach marks nothing (no document yet): not a miss.
                if outcome == "Z", document != nil {
                    TerminalHistoryWindowProbe.shared.lastMiss = TerminalHistoryWindowProbe.shared.lastReset
                }
                #endif
                // Held for the keyboard: the frame is held when it is fed.
                if replayHold.arrived(event, isTUI: model.isTUI, heldRows: tuiGridHold.heldRows, pageRows: tuiRows).takeHeldFrame {
                    freezeLastFrame()
                }
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
                model.mirrorResets += 1
                replayStartedAt = CACurrentMediaTime()
                replayBytes = 0
            } else if replayGate.isReplaying {
                replayBytes += data.count
            }
            replayGate.received(data.count, isReset: isReset, at: CACurrentMediaTime())
            pacer.arrived(at: CACurrentMediaTime())
            #if DEBUG
            if TerminalFrameLog.isEnabled { frameLog.outputArrived() }
            rttLog.outputArrived(bytes: data.count)
            #endif
            // Per chunk: queue the bytes and nothing else. Parsing, the row
            // shift and the artifact scan happen once per display frame.
            model.ingest(event)
            paintTally.handed(data.count)
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
            // The Mac's shorter grid while the keyboard still rises: it and
            // what follows wait for the keyboard to stop (`replayHold`).
            _ = replayHold.arrived(event, isTUI: model.isTUI, heldRows: tuiGridHold.heldRows, pageRows: tuiRows)
            // In order with the bytes too: the mirror takes the Mac's new
            // grid right before the first byte drawn for it. An answer to a
            // resize older than the newest waits in the queue; the newest
            // answer drops it (its reset clears whatever it would draw).
            let stale = answerIsStale(.init(columns: columns, rows: rows))
            output.append(hostGrid: columns, rows: rows, stale: stale)
            if stale {
                sizingLog.notice("answer \(columns, privacy: .public)x\(rows, privacy: .public) is for an older resize: it waits for the newest")
                armStaleAnswerExpiry()
            } else if output.dropStaleAnswers() > 0 {
                sizingLog.notice("older answers dropped: the newest one is \(columns, privacy: .public)x\(rows, privacy: .public)")
                // A dropped grid may have been the one the keyboard hold
                // waits for: the hold is judged again for the newest.
                replayHold.gridTaken()
                _ = replayHold.arrived(event, isTUI: model.isTUI, heldRows: tuiGridHold.heldRows, pageRows: tuiRows)
            }
            scheduleOutput()
        case .hostGridOwner(let name):
            // In order with the grid events: the owner and the grid it set
            // change together, never the name first next to the old grid.
            if output.isEmpty {
                hostGridOwner = name
            } else {
                output.append(hostGridOwner: name)
                scheduleOutput()
            }
        case .paintMark(let seq, let receivedMs):
            paintTally.mark(seq: seq, receivedMs: receivedMs)
        case .inputNotSent:
            // Keys refused, or held through an outage and dropped: their
            // predicted glyphs would stand for keys that never arrive.
            inputRefused = true
            surface.prediction?.inputDropped()
            model.ingest(event)
        case .connection(let state):
            // The link went down with keys on it: the ones in flight may be
            // held, resent or dropped, and their echoes may never come.
            if !state.isAttached { surface.prediction?.inputDropped() }
            model.ingest(event)
        default:
            model.ingest(event)
        }
    }

    /// Stamped redraws (`.paintMark`) waiting for the present that shows them.
    private var paintTally = TerminalPaintTally()
    /// Session bytes Ghostty parsed so far, and as of the last present.
    private var paintParsed = 0
    private var paintParsedAtPresent = 0

    /// A present showed every byte parsed before it: the stamped redraws among them were painted.
    private func paintPresented() {
        guard paintParsed != paintParsedAtPresent else { return }
        paintParsedAtPresent = paintParsed
        let now = TerminalPaintReport.nowMs
        paintTally.presented(parsed: paintParsed, atMs: now)
        if let samples = paintTally.takeReport(nowMs: now) { model.session.reportPaint(samples) }
    }

    /// The session refused the input `send` was just given (`.inputNotSent`
    /// during the call): prediction does not record it.
    private var inputRefused = false

    /// Feeds at once when nothing was fed in this display frame (an echo is
    /// not held back to the next frame); otherwise the display link feeds at
    /// the start of the next frame. Either way, at most one batch per frame.
    /// A page nobody can see feeds on `hiddenFeedInterval` instead (`feedsHidden`).
    private func scheduleOutput() {
        // Held for the keyboard: no display link meanwhile (`keyboardStopped`
        // schedules again).
        if replayHold.holding { return }
        if feedsHidden { return armHiddenFeed() }
        if pacer.canFeed(at: CACurrentMediaTime()) {
            pumpOutput()
        } else {
            armBurstWake()
        }
        guard outputLink == nil, !output.isEmpty || feedInFlight else { return }
        let link = CADisplayLink(target: DisplayLinkProxy(owner: self) { [weak self] in
            // A new frame: one more batch may go.
            self?.outputCounts.frameTicks += 1
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

    /// The queue's next step is the Mac's shorter grid that came while the
    /// keyboard rose, and the keyboard still moves: hold there
    /// (`replayHold`), until `keyboardStopped` or the movement's end.
    private func holdsAtGrid() -> Bool {
        if replayHold.holding { return true }
        // An older resize's answer waits for the newest one (or its expiry).
        if output.nextHostGridIsStale {
            stopOutputLink()
            return true
        }
        guard replayHold.holdsAt(nextIsGrid: output.nextHostGrid != nil) else { return false }
        stopOutputLink()
        let deadline = max(0, keyboardMoveEnds - CACurrentMediaTime()) + 0.1
        let movement = keyboardMovement
        DispatchQueue.main.asyncAfter(deadline: .now() + deadline) { [weak self] in
            // A did-show or did-hide that never came (filtered, or a page
            // that left): the hold ends with the movement (not a newer one).
            guard let self, self.replayHold.holding, self.keyboardMovement == movement else { return }
            self.keyboardStopped()
        }
        return true
    }

    /// Hands Ghostty the next batch. `catchUp` (a hidden page's turn, or the
    /// page shown again) takes up to `hiddenFeedBudget` bytes in one batch,
    /// with no wait for a display frame or a burst's end: nothing is drawn
    /// until the page is seen, and once it is, what it shows is current.
    private func pumpOutput(catchUp: Bool = false) {
        outputCounts.pumps += 1
        // The Mac's redraw waits for the keyboard to stop (`replayHold`).
        if replayHold.holding { return }
        if !catchUp, !pacer.canFeed(at: CACurrentMediaTime()) {
            armBurstWake()
            return
        }
        let budget = catchUp
            ? Self.hiddenFeedBudget
            : TerminalOutputQueue.budget(interacting: scroll.isInteracting && !Self.legacyInteraction)
        while !feedInFlight, !holdsAtGrid(), let step = output.next(budget: budget) {
            switch step {
            case .alternateScreen(let on):
                model.ingest(.alternateScreen(on))
                applyMode(tui: on)
            case .hostGrid(let columns, let rows):
                replayHold.gridTaken()
                appliedHostColumns = columns
                appliedHostRows = rows
                if !model.isTUI, columns != hostLayout.phoneColumns {
                    model.wideGridsShown += 1
                    sizingLog.notice("wide grid on the primary screen: \(columns, privacy: .public) columns (phone \(self.hostLayout.phoneColumns, privacy: .public))")
                }
                // The Mac's grid changed: a resize the phone sent before is answered.
                if TerminalResizeSettle.Size(columns: columns, rows: rows) != sentGridBefore { sentGridBefore = nil }
                syncHostGrid()
            case .hostGridOwner(let name):
                hostGridOwner = name
            case .bytes(let data):
                syncHostGrid()
                outputCounts.batches += 1
                pacer.started(frameEnd: outputLink?.targetTimestamp ?? CACurrentMediaTime() + frameInterval,
                              queueEmpty: output.isEmpty)
                model.scanOutput(data)
                firstEcho.fed(data)
                #if DEBUG
                echoMeter.fed(data)
                devProbe?.fed(data)
                #endif
                let transform: (@Sendable (Data) -> Data)?
                if let remote = feedHostRows {
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

    // MARK: Output of a page nobody can see

    /// The page cannot be seen (out of its window: a warm tab behind
    /// another; or the app in the background): its output reaches Ghostty
    /// with no display link, in one batch per `hiddenFeedInterval` (Chrome's
    /// background-tab timer throttling: work nobody can see runs at most once
    /// a second). The mirror stays exact (every byte is parsed, in order, and
    /// backpressure still pauses the Mac), and shown again the page catches up
    /// at once (`pageShownChanged`). A reset's replay is fed as when shown:
    /// the replay gate's deadline counts from the reset.
    private var feedsHidden: Bool {
        surface.surface != nil && !surface.isShown && !replayGate.isReplaying
    }
    /// The hidden page's next turn; nil when none is due (one at a time,
    /// armed only while output waits).
    private var hiddenFeed: DispatchWorkItem?
    /// The most a hidden page hands Ghostty in one batch. A backlog of a
    /// full batch or more (a flood) goes on as soon as Ghostty parsed the
    /// last one, so the queue drains and backpressure lifts; Ghostty holds
    /// its terminal lock for a batch, so it stays short enough for the page
    /// shown in the middle of one.
    static let hiddenFeedBudget = 1 << 20

    /// Output waits on a hidden page: its next turn comes at most
    /// `hiddenFeedInterval` from now. Stops the display link and a burst
    /// wake; arms nothing when the queue is empty or a batch is in flight
    /// (the batch's end looks again, `continueAfterBatch`).
    private func armHiddenFeed() {
        stopOutputLink()
        burstWake?.cancel()
        burstWake = nil
        guard hiddenFeed == nil, !output.isEmpty, !feedInFlight else { return }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hiddenFeed = nil
                self.pumpOutput(catchUp: true)
            }
        }
        hiddenFeed = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hiddenFeedInterval, execute: item)
    }

    /// A batch was parsed: on a hidden page, a full batch's backlog goes on
    /// now and a smaller rest waits for the next turn; on a shown one, the
    /// display link goes on while output waits.
    private func continueAfterBatch() {
        if feedsHidden {
            if output.pendingBytes >= Self.hiddenFeedBudget {
                pumpOutput(catchUp: true)
            } else {
                armHiddenFeed()
            }
        } else if output.isEmpty {
            stopOutputLink()
        } else if outputLink == nil {
            // Shown while a hidden batch was in flight: the rest goes per frame.
            scheduleOutput()
        }
    }

    /// The surface's page came into view or left it (`TerminalSurfaceView.onShownChange`).
    private func pageShownChanged(_ shown: Bool) {
        guard shown else {
            // Hidden: the display link stops and output waits for the hidden turn.
            if feedsHidden { armHiddenFeed() }
            return
        }
        hiddenFeed?.cancel()
        hiddenFeed = nil
        guard !output.isEmpty || feedInFlight else { return }
        // Shown: what waited goes to Ghostty now, before the first frame,
        // and the rest (a flood's backlog) per display frame after it.
        pacer.newFrame()
        if !feedInFlight { pumpOutput(catchUp: true) }
        scheduleOutput()
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
        // Copy Mode first: the selection it drew moves with it, so the selection's shift
        // below reads as its own drawing, not a finger's change.
        copyMode.shiftRows(by: -rows)
        selection.shiftRows(by: -rows)
        finder.shiftRows(by: -rows)
        copyModeRows = nil
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
    /// A reader's place still to be put back across resets: one handed over
    /// from the tab's previous host (``restoreScrollPlace(_:)``), or one above
    /// the rows a replay held, waiting for the older rows it asked for
    /// (`TerminalScrollRestore`). The next replay places it.
    private var pendingRestore: TerminalScrollRestore?
    /// Older rows were asked for and their reset has not come yet: the replay
    /// deadline and the held frame's cap leave the pending place alone until
    /// it does (a restore then would find the rows still missing).
    private var olderRowsAsked = false
    /// Scroll to Top asked for older rows: the replay they come in is read
    /// from its first row and asks again, until the session has none (the
    /// Mac's Scroll to Top reaches its first row; a projection holds a window).
    private var topAsked = false
    /// Flings a reset stopped to place the reader (demo and bench readout,
    /// `historyfling`).
    private(set) var flingsStoppedByReset = 0
    /// A fling reached within a screen of the oldest row held: the older
    /// rows are asked for when it ends. Their replay starts with a reset,
    /// and a reset stops a fling to place the reader, so asking mid-fling
    /// cut the first fling up short (Leo, 2026-11-21: "this claude code cli
    /// is often slow to scroll up and down from ios").
    private var olderRowsWanted = false
    /// A place is waiting to be put back (the held frame stays for it).
    private var restorePending: Bool { readingMark != nil || pendingRestore != nil }
    /// A place is waiting and the replay that places it is in (or overdue).
    private var restoreDue: Bool { readingMark != nil || topAsked || (pendingRestore != nil && !olderRowsAsked) }

    /// The reset's replay is parsed: put a reader back on their rows.
    private func restoreReadingMark() {
        let ownMark = pendingRestore == nil
        let pending = pendingRestore ?? readingMark.map { TerminalScrollRestore(mark: $0, fromEnd: false) }
        readingMark = nil
        pendingRestore = nil
        olderRowsAsked = false
        readingMarkAwaitsReport = false
        fingerRestore = nil
        #if DEBUG
        let markOffsetY = readingMarkOffsetY
        #endif
        readingMarkOffsetY = nil
        let held = scrollView.isTracking || scrollView.isDecelerating
        if topAsked {
            topAsked = false
            guard !model.isTUI, !held else { return }
            scroll.restoreReading(.init(row: 0, delta: -scrollView.adjustedContentInset.top))
            topAsked = model.session.loadOlderHistory()
            return
        }
        // A gesture since the reset moved a page whose rows are the old
        // replay's: the scroll model decides where the reader goes
        // (`TerminalScrollModel.restoreReading`). Only the reader's own mark:
        // a place waiting for older rows is dropped by the drag
        // (`dropPendingRestore`).
        guard var restore = pending, !model.isTUI, !held || ownMark else {
            #if DEBUG
            if pending != nil, !model.isTUI { TerminalHistoryWindowProbe.shared.note("T") }
            #endif
            return
        }
        let total = scrollbar.total
        let reader = rowReader
        // Every row of the replay, read once (the whole-screen read is not
        // clamped to the grid; round 9): the rows far from the end are found
        // by their text too, so output during the drop cannot push the reader
        // down (T-LIFE-09/15). Rows past the read's trimmed end use the reader.
        let screen = surface.screenRows()
        let session = model.session
        guard let anchor = restore.replayed(totalRows: total, rowText: { row in
            if let screen, row < screen.count { return screen.rows[row] }
            return reader.text(TerminalAbsoluteRow(row))
        }, loadOlder: { session.loadOlderHistory() }) else {
            // The reader is above the rows replayed: the older rows' replay
            // (a reset) comes back here.
            pendingRestore = restore
            olderRowsAsked = true
            let fromEnd = restore.mark.rowsFromEnd
            let loads = restore.olderLoads
            #if DEBUG
            TerminalHistoryWindowProbe.shared.note("S")
            #endif
            sizingLog.notice("reading mark \(fromEnd, privacy: .public) rows from the end, above the \(total, privacy: .public) replayed: older rows asked (\(loads, privacy: .public))")
            return
        }
        let placed = restore.mark
        #if DEBUG
        // The scroll state at the report and the rows the page moved since
        // the mark (a gesture, or the reset's follow to the bottom).
        let stateLetter: String
        switch scroll.state {
        case .following: stateLetter = "f"
        case .reading: stateLetter = "r"
        case .interacting: stateLetter = held ? "h" : "i"
        }
        let movedRows = markOffsetY.map { cell.height > 0 ? Int(((scrollView.contentOffset.y - $0) / cell.height).rounded()) : 0 }
        TerminalHistoryWindowProbe.shared.lastPlace = "\(stateLetter)\(movedRows.map { $0 >= 0 ? "+\($0)" : "\($0)" } ?? "?")@\(anchor.row)/\(total)\(scrollView.isTracking ? "t" : (scrollView.isDecelerating ? "d" : ""))"
        #endif
        sizingLog.notice("reading mark restored row \(placed.row, privacy: .public) -> \(anchor.row, privacy: .public) of \(total, privacy: .public) (scroll \(String(describing: self.scroll.state), privacy: .public))")
        if let underGesture = scroll.restoreReading(anchor) {
            // A finger or its fling holds the page: placed once the document
            // has the replay's rows (`applyFingerRestore`).
            fingerRestore = underGesture
            #if DEBUG
            TerminalHistoryWindowProbe.shared.note("F")
            #endif
            return
        }
        guard scroll.state == .reading(anchor) else {
            // The scroll model kept another state: the page stays on the old
            // rows' offset in the new rows.
            #if DEBUG
            TerminalHistoryWindowProbe.shared.note("K")
            #endif
            return
        }
        restoredMark = (placed, anchor)
        #if DEBUG
        TerminalHistoryWindowProbe.shared.note("P")
        #endif
    }

    /// A reader's rows found while a finger or its fling held the page
    /// (`restoreReadingMark`).
    private var fingerRestore: TerminalScrollModel.Anchor?
    /// The page's offset when the reading mark was taken (DEBUG probe only:
    /// after the reset the page follows the old document's bottom, so this
    /// is not the finger's move).
    private var readingMarkOffsetY: CGFloat?

    /// After the document took the replay's rows: a reader restored under a
    /// finger or a fling gets the page moved to their rows. A fling is
    /// stopped there and the page rests on those rows: its settle reads the
    /// reader's rows (`TerminalScrollModel.settled`), and a drag that begins
    /// before the page has their frame starts on them.
    private func applyFingerRestore() {
        guard let restore = fingerRestore else { return }
        fingerRestore = nil
        guard let document, cell.height > 0, !model.isTUI else {
            #if DEBUG
            TerminalHistoryWindowProbe.shared.lastFinger = "\(restore.row)x\(document == nil ? "doc" : (model.isTUI ? "tui" : "cell"))"
            #endif
            return
        }
        let target = document.contentY(ofRow: restore.row, cellHeight: cell.height) + restore.delta
        let y = min(max(-scrollView.contentInset.top, target), maxOffsetY)
        let decelerating = scrollView.isDecelerating || fling != nil
        #if DEBUG
        let probeGesture = scrollView.isTracking ? "t" : (decelerating ? "d" : "")
        defer {
            let state: String
            switch scroll.state {
            case .following: state = "f"
            case .reading: state = "r"
            case .interacting: state = "i"
            }
            TerminalHistoryWindowProbe.shared.lastFinger = "\(restore.row)y\(document.row(atContentY: max(0, y), cellHeight: cell.height))max\(document.row(atContentY: max(0, maxOffsetY), cellHeight: cell.height))\(probeGesture)>\(state)\(scroll.awaitsPlacement ? "u" : "")@\(document.row(atContentY: max(0, scrollView.contentOffset.y), cellHeight: cell.height))"
        }
        #endif
        if decelerating {
            fling?.stop()
            fling = nil
            stopGlide()
        }
        settingOffset = true
        if decelerating {
            scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: y), animated: false)
        } else {
            scrollView.contentOffset.y = y
        }
        settingOffset = false
        updateViewport(visibleMinY: scrollView.contentOffset.y)
        if decelerating, !scrollView.isTracking { settleScroll() }
    }

    /// Where the reader is, for the tab's next host when the warm set cools
    /// this one: nil while following the prompt (the next host follows too)
    /// and in a full-screen app, which has no scrollback.
    func scrollPlace() -> TerminalScrollPlace? {
        if let pendingRestore { return pendingRestore.place }
        if let readingMark { return TerminalScrollPlace(mark: readingMark) }
        guard !model.isTUI, cell.height > 0, let anchor = readingAnchor() else { return nil }
        let reader = rowReader
        return TerminalReadingMark(anchor: anchor, totalRows: scrollbar.total) { reader.text(TerminalAbsoluteRow($0)) }
            .map { TerminalScrollPlace(mark: $0) }
    }

    /// The tab's previous host kept the reader's place: the first replay puts
    /// them back (asking for older rows when it holds too few).
    func restoreScrollPlace(_ place: TerminalScrollPlace) {
        pendingRestore = TerminalScrollRestore(place: place)
    }

    /// The person took the page (a drag, typing, Jump to bottom): a place
    /// still waiting for its replay is dropped.
    private func dropPendingRestore() {
        topAsked = false
        guard pendingRestore != nil else { return }
        pendingRestore = nil
        olderRowsAsked = false
        #if DEBUG
        TerminalHistoryWindowProbe.shared.note("D")
        #endif
        sizingLog.notice("reading mark dropped: the person moved the page")
    }

    /// The rows at the top of the page while the reader is away from the
    /// prompt, whatever the scroll state; nil while following (or within
    /// `followSlackRows` of the bottom mid-gesture).
    private func readingAnchor() -> TerminalScrollModel.Anchor? {
        switch scroll.state {
        case .following:
            return nil
        case .reading(let reading):
            return reading
        case .interacting:
            guard let document, scrollView.contentOffset.y < maxOffsetY - TerminalScrollModel.followSlackRows * cell.height else { return nil }
            return TerminalScrollModel.anchor(offsetY: scrollView.contentOffset.y, layout: document, rowHeight: cell.height)
        }
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
        // A place still waiting for its replay (handed over, or older rows
        // asked for) is the reader's: this replay places it.
        guard !model.isTUI, readingMark == nil, pendingRestore == nil, cell.height > 0 else { return }
        // Mid Jump to bottom: the reader asked for the bottom, not the row
        // the glide was passing.
        if glide != nil {
            stopGlide(thenFollow: true)
            restoredMark = nil
            #if DEBUG
            probeMarkMiss = "glide"
            #endif
            return
        }
        guard let anchor = readingAnchor() else {
            restoredMark = nil
            #if DEBUG
            probeMarkMiss = "anchor"
            #endif
            return
        }
        #if DEBUG
        // The anchor, the rows Ghostty holds, its viewport's top and its grid's rows.
        probeMarkMiss = "text\(anchor.row)/\(scrollbar.total)v\(scrollbar.offset)g\(surface.grid.rows)"
        #endif
        if scrollView.isDecelerating || fling != nil {
            flingsStoppedByReset += 1
            fling?.stop()
            fling = nil
            stopGlide()
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
        readingMarkOffsetY = readingMark == nil ? nil : scrollView.contentOffset.y
        sizingLog.notice("reading mark row \(anchor.row, privacy: .public) of \(self.scrollbar.total, privacy: .public): \(self.readingMark == nil ? "none" : "kept", privacy: .public)")
    }

    #if DEBUG
    /// Why the last reset marked nothing (`TerminalHistoryWindowProbe.lastReset`).
    private var probeMarkMiss = "-"

    /// The scroll state for the probe: `f`, `r` or `i`, `u` while a restore
    /// has not reached its rows, `t` a finger or `d` a deceleration.
    private func probeResetContext() -> String {
        var context: String
        switch scroll.state {
        case .following: context = "f"
        case .reading: context = "r"
        case .interacting: context = "i"
        }
        if scroll.awaitsPlacement { context += "u" }
        if scrollView.isTracking || scrollView.isDragging {
            context += "t"
        } else if scrollView.isDecelerating {
            context += "d"
        }
        return context
    }
    #endif

    /// The replay gate's own deadline (V3-2): the document is never left
    /// ungrown past it, held frame or not.
    private func armReplayDeadline() {
        DispatchQueue.main.asyncAfter(deadline: .now() + TerminalReplayGate.deadline) { [weak self] in
            guard let self, self.replayGate.expireIfOverdue(at: CACurrentMediaTime()) else { return }
            sizingLog.notice("replay gate expired at its deadline")
            self.model.mirrorPlaced()
            self.outputSinceProbe = true
            self.updateDocument()
            if self.restoreDue {
                self.restoreReadingMark()
                self.updateDocument()
                self.applyFingerRestore()
            }
            self.applyScroll()
            if let held = self.freezeView, !self.restorePending { self.releaseHeldFrameAtCap(ObjectIdentifier(held), recover: true) }
        }
    }

    /// Ghostty parsed a batch (`raw` session bytes).
    private func outputProcessed(_ raw: Int) {
        pacer.finished()
        paintParsed += raw
        // A full-screen app taller than the phone (the Mac's rows as of the
        // bytes fed, `feedHostRows`), or partly under the keyboard: keep its
        // cursor row on screen.
        let areaRows = tuiGridHold.rows(page: tuiRows)
        if model.isTUI, tuiRowShift > 0 || (feedHostRows ?? 0) > areaRows
            || tuiKeyboardLift > 0 || tuiClip.bounds.height < CGFloat(areaRows) * cell.height - 0.5 {
            applyTUIPlacement()
        }
        firstEcho.processed()
        #if DEBUG
        echoMeter.processed()
        devProbe?.processed()
        // Every parsed byte, the reset and replay the gate holds included:
        // the bench's echo and drain offsets count them (fleet bench
        // 2026-10-26: a 2-byte gap read idle echo as 413 ms, drain as -1).
        TerminalBenchProbe.shared?.outputProcessed(raw)
        #endif
        let replayDone = replayGate.parsed(raw)
        finder.outputArrived()
        if replayGate.isReplaying {
            // A reset's replay is still being fed: no layout, no frame swap
            // until all of it is parsed (user report 2026-10-14).
            outputSinceProbe = true
            if output.isEmpty { stopOutputLink() }
            return
        }
        if replayDone {
            // The Mac's grid is parsed: the area takes the page's rows now,
            // behind the held frame, which the next present lets go (or the
            // replay's rows, while the page's own answer is still coming).
            gridReplayed()
            model.mirrorPlaced()
            if let started = replayStartedAt {
                sizingLog.notice("replay done bytes=\(self.replayBytes, privacy: .public) ms=\(Int((CACurrentMediaTime() - started) * 1000), privacy: .public)")
                replayStartedAt = nil
            }
            outputSinceProbe = true
            // Ghostty's next scrollbar report has the replay's row count.
            if restoreDue { readingMarkAwaitsReport = true }
            updateDocument()
            // The mirror was reset and replayed: an open find searches the new rows.
            finder.rowsReplaced()
        }
        if freezeView != nil, raw > Self.mirrorReset.count || replayDone, replayHasContent() {
            // The replay is parsed and draws something: drop the held frame on
            // the next present (or after one more batch, whichever comes first).
            freezeBatches += 1
            // A full-screen app's area swaps with the still on a present
            // (surfacePresented), once Ghostty has drawn the new grid.
            if freezeBatches >= 2, !(areaSwapPending && model.isTUI), heldFrameMayGo() { unfreeze() }
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
        continueAfterBatch()
    }

    private func surfaceEvent(_ event: TerminalSurfaceEvent) {
        switch event {
        case .scrollbar(let total, let offset, let visible):
            measured("scrollbar") { scrollbarReported(total: total, offset: offset, visible: visible) }
        case .cellSize:
            // Ghostty reports its cell size on every font grid it builds: the
            // zoom's `set_font_size` and again for the theme update queued
            // after it (`applyFontSize`), at the same size. Only a new size
            // lays out, and at once: the surface's frame takes the new rows in
            // the same turn as Ghostty's new cells, not on a later pass after
            // a frame drawn at the old frame. The first size (the surface is
            // created, maybe inside a layout) waits for the next pass.
            if surface.cellSize != cell {
                view.setNeedsLayout()
                if cell.height > 0 { view.layoutIfNeeded() }
            }
            if model.isTUI { finder.rowsReplaced() }
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
        if restoring { applyFingerRestore() }
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
    static let mirrorReset = TerminalReclaimHold.reset

    /// Holds what is on screen until the replay after a reset is drawn. Only
    /// once the page has drawn something (the first attach has nothing to hold).
    /// `pageWide`: the app is leaving the alternate screen (its replay or the
    /// event at hand turns it off): the area is about to be hidden, so the
    /// still is of the whole page.
    private func freezeLastFrame(pageWide: Bool = false) {
        // Never while the page is being scrolled: the still would stand over
        // the moving rows and show an older position until the replay was in
        // (user report 2026-10-14, frames alternating near the bottom).
        guard freezeView == nil, view.window != nil, document != nil || model.isTUI,
              !scrollView.isTracking, !scrollView.isDecelerating else { return }
        // A full-screen app's frame is its area alone: the rest of the page
        // (the composer's glass, the key row) stays live above the backing,
        // and a still of the whole page cost 10-15 ms on the frame the
        // keyboard stopped (the held replay's reset, step f97802b9).
        let areaStill = model.isTUI && !pageWide && !output.leavesAlternateScreen
        let source: UIView = areaStill ? tuiHost : view
        // The grid's host, whose height is the grid's (not the clip's, which
        // animates with the keyboard: a still of it mid-animation is drawn at
        // the clip's end size, its grid a few points off the moving composer),
        // widened by the side padding a panned or wider surface reaches into.
        let wide = CGRect(x: -Self.sidePadding, y: 0, width: tuiHost.bounds.width + 2 * Self.sidePadding, height: tuiHost.bounds.height)
        guard let snapshot = measured("hold-frame-snapshot", {
            areaStill ? tuiHost.resizableSnapshotView(from: wide, afterScreenUpdates: false, withCapInsets: .zero)
                : view.snapshotView(afterScreenUpdates: false)
        }) else { return }
        snapshot.isUserInteractionEnabled = false
        if source === view {
            snapshot.frame = view.bounds
            view.insertSubview(snapshot, belowSubview: bottomBacking)
        } else {
            // In the grid's own host, where it was taken, top-pinned with it:
            // the host stands at the toolbar's edge while the composer moves.
            snapshot.frame = wide
            snapshot.autoresizingMask = [.flexibleBottomMargin]
            tuiHost.addSubview(snapshot)
        }
        // On screen before Ghostty can present the replay: its renderer
        // presents on its own thread, and a present that beat this pass's
        // commit showed the new grid in the old area for a frame (htop's
        // first show, a source frame of 5 ms).
        CATransaction.flush()
        freezeView = snapshot
        #if DEBUG
        freezeCount &+= 1
        // The rows the area shows as the still is taken (the Mac's new grid
        // may be applied already: its change comes before the reset).
        freezeRows = cell.height > 0 ? Int((tuiHeight.constant / cell.height).rounded()) : 0
        #endif
        #if DEBUG
        heldCommitted = true
        #endif
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
                self.model.mirrorPlaced()
                self.outputSinceProbe = true
                self.updateDocument()
            }
            if self.restoreDue {
                self.restoreReadingMark()
                self.updateDocument()
                self.applyFingerRestore()
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
        #if DEBUG
        heldCommitted = false
        #endif
        // The new grid is presented: the area takes its rows in this pass,
        // with the still's removal (one commit).
        if areaSwapPending { swapArea() }
        freezeView?.removeFromSuperview()
        freezeView = nil
        freezeBatches = 0
        holdAwaitsReset = false
    }

    /// The app left (false) or is coming back to (true) the foreground.
    ///
    /// Leo, 2026-11-12: "when i load in it show me uncompact then squish". The
    /// background releases the phone's size at once, so the Mac's grid grows;
    /// the mirror follows it, and coming back would show the Mac's wide grid
    /// until the reclaim's resize reset the mirror at the phone's size. The page as it was when
    /// the app left (the phone's own grid) now stays up until that reset's
    /// replay is drawn: one steady frame at phone width.
    func appActiveChanged(_ active: Bool) {
        guard active else {
            backgroundStill = view.window != nil && !hostLayout.differsFromPhone
                ? view.snapshotView(afterScreenUpdates: false) : nil
            return
        }
        // Back in the foreground: UIKit posted no hide for a keyboard that
        // went while the app was away, so the dock may still hold its inset.
        keyboardTracker.dropKeyboardWithoutOwner()
        let still = backgroundStill
        backgroundStill = nil
        guard let still, freezeView == nil, view.window != nil, hostLayout.differsFromPhone else { return }
        sizingLog.notice("foreground: the Mac's grid is not the phone's; the page from before holds until the reclaim's replay")
        still.frame = view.bounds
        still.isUserInteractionEnabled = false
        view.insertSubview(still, belowSubview: bottomBacking)
        freezeView = still
        freezeBatches = 0
        placedSinceHold = false
        freezeStarted = CACurrentMediaTime()
        holdAwaitsReset = true
        let held = ObjectIdentifier(still)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.freezeCap) { [weak self] in
            guard let self, let view = self.freezeView, ObjectIdentifier(view) == held else { return }
            // No reset came (the Mac kept its grid): the live page shows.
            if self.holdAwaitsReset {
                self.unfreeze()
            } else {
                self.releaseHeldFrameAtCap(held, recover: true)
            }
        }
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
        if measured.height > 0, measured != cell {
            let previous = cell
            cell = measured
            if previous.height > 0 { cellSizeChanged(from: previous) }
        }
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
        laidOutHostRows = layout.hostRows
        let surfaceSize = CGSize(width: layout.surfaceWidth, height: CGFloat(rows) * cellHeight)
        if surface.bounds.size != surfaceSize {
            UIView.performWithoutAnimation {
                surface.frame.size = surfaceSize
                surface.layoutIfNeeded()
            }
        }

        // TUI rows: toolbar bottom to the composer's resting top (keyboard
        // down). Showing or closing the keyboard insets the grid instead of
        // resizing the Mac's PTY (`TerminalGridSizing`).
        let newTUIRows = TerminalGridSizing(cellHeight: cellHeight).rows(restingStackTop: restingStackTop, chromeTop: chromeTop)
        // The phone claims its own grid; only the rendering follows the Mac's.
        let columns = layout.phoneColumns
        // Only a rows-only change (a chrome change: Hide Toolbar, a tab's
        // insets; never the soft keyboard) is held: a new width (a rotation)
        // shows the page's grid, letterboxed or shifted to the cursor as it
        // is, until the Mac redraws.
        if newTUIRows != tuiRows, model.isTUI, tuiRows > 0, columns == gridColumns {
            tuiGridHold.rowsChanged(from: tuiRows, to: newTUIRows, shownRows: appliedHostRows ?? model.session.remoteRows)
            armGridHoldExpiry()
        }
        if newTUIRows != tuiRows || columns != gridColumns {
            tuiRows = newTUIRows
            gridColumns = columns
        }
        // The area keeps the grid on screen until the Mac's new one is in.
        applyTUIAreaHeight(cellHeight: cellHeight)
        if columns > 0 { measuredGrid(columns: columns, rows: newTUIRows) }
        applyContentWidth()
        applyTUIPlacement()

        // Insets: content starts under the toolbar and ends above the composer.
        let top = chromeTop
        // The last row rests 8 pt above the composer card (SPEC M3).
        var bottom = TerminalDocumentLayout.bottomInset(pageHeight: bounds.height, composerTop: bottomStack.frame.minY)
        // A grid shorter than the page pins to the top: its last row rests
        // above the letterbox, not on the composer.
        let pins = pinsHostGrid
        if pins, let pinned = hostLayout.pinnedBottomInset(pageHeight: bounds.height, top: top) {
            bottom = max(bottom, pinned)
        }
        if pins != documentPinsHostGrid {
            // The pin came or went (the Mac's rows, the keyboard): measure the document again now.
            documentPinsHostGrid = pins
            outputSinceProbe = true
            updateDocument()
        }
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
                } else if !scrollView.isTracking, !scrollView.isDragging, !scrollView.isDecelerating, glide == nil, cell.height > 0,
                          let target = scroll.target(layout: document, rowHeight: cell.height, topInset: scrollView.contentInset.top,
                                                     bottomOffsetY: maxOffsetY) {
                    // Following: the offset moves here, in this pass, so it
                    // rides the keyboard's animation. Left to applyScroll, a
                    // stream's newest rows not yet presented made it wait for
                    // a frame (jumpAwaitsFrame) and then move in one step,
                    // outside the animation: the rows jumped up to their end
                    // with the keyboard still rising and the composer caught
                    // up with them (up to 400 pt of background between).
                    // The rows a frame behind are the newest, at the bottom;
                    // the next present brings them.
                    settingOffset = true
                    scrollView.contentOffset.y = target
                    settingOffset = false
                    // Ghostty draws the rows at the new offset too.
                    updateViewport(visibleMinY: target)
                }
            }
        }
        applyHostGridNote()
    }

    /// The font size changed (the key row's zoom keys, Settings): in this
    /// layout pass, before the scroll target is read, the document takes the
    /// new row height and a reader keeps the first row they see. Left to the
    /// next scrollbar report, the page's bottom was the old row height's for
    /// a frame or more (the last rows under the composer after a zoom in,
    /// a gap above it after a zoom out), then jumped.
    private func cellSizeChanged(from previous: CGSize) {
        guard !model.isTUI, previous.height != cell.height else { return }
        scroll.rowHeightChanged(from: previous.height, to: cell.height, topInset: scrollView.contentInset.top)
        if let document { setContentHeight(document.contentHeight(cellHeight: cell.height)) }
        // Ghostty rewraps at the new columns: the next update measures the rows again.
        outputSinceProbe = true
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
        // The Mac's screen is the bottom `remoteRows` rows of the mirror.
        let screenTop = max(0, scrollbar.total - (feedHostRows ?? surface.grid.rows))
        // Rows an inline TUI draws below the cursor (Codex CLI's hints).
        var lastContent: Int?
        if documentPinsHostGrid {
            // A grid shorter than the page is shown whole, pinned to the top
            // with the letterbox below it: the document holds all its rows,
            // blank ones at its top too, and ends at its last row.
            blank = min(blank ?? screenTop, screenTop)
            lastContent = scrollbar.total - 1
        } else if let cursor, cursor + 1 <= scrollbar.total - 1 {
            lastContent = rowReader.lastNonBlankRow(from: TerminalAbsoluteRow(cursor + 1), through: TerminalAbsoluteRow(scrollbar.total - 1))?.index
        }
        let measured = TerminalDocumentLayout.make(totalRows: scrollbar.total, cursorRow: cursor, leadingBlankRows: blank,
                                                   lastContentRow: lastContent)
        if document == nil { endHold.reset() }
        let next = endHold.hold(measured, totalRows: scrollbar.total, cursorRow: cursor, screenTopRow: screenTop)
        guard next != document else {
            positionHostGridNote()
            return
        }
        let shift = CGFloat(next.originRow - originRow) * cell.height
        let hadDocument = document != nil
        document = next
        setContentHeight(next.contentHeight(cellHeight: cell.height))
        positionHostGridNote()
        if hadDocument, shift != 0 {
            // The top moved (cleared, or found): the frame on screen goes
            // where its rows now belong.
            place(atRow: presentedTop)
            selection.redraw()
            tuiSelection.redraw()
            finder.redraw()
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
        stopGlide()
        dropPendingRestore()
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
        // Jump to bottom's glide waiting for its entry's frame asks for the
        // entry's rows the same way (a report in between asked again for the
        // reader's rows, and the entry was never drawn).
        let entry = glide?.pendingEntry
        let visibleMinY = TerminalScrollGate.requestOffset(awaiting: followAwaitsPresent || entry != nil, current: requested,
                                                           target: entry ?? (followAwaitsPresent ? pendingTarget : nil))
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
        if firstEcho.presented() { LaunchMarks.shared.mark("terminal_echo_presented") }
        paintPresented()
        #if DEBUG
        if echoMeter.presented() {
            InputLatencyTrace.shared?.sample("terminal_key_echo", since: echoStart)
            echoMeter = TerminalFirstEcho()
        }
        #endif
        if model.connectionState.isAttached { LaunchMarks.shared.mark("terminal_ready") }
        #if DEBUG
        if let probe = TerminalBenchProbe.shared {
            probe.presented()
            if probe.readScreen == nil {
                probe.readScreen = { [weak self] in self?.surface.screenRows()?.rows }
            }
        }
        devProbe?.presented()
        #endif
        #if DEBUG
        // What Ghostty just presented against what covers it: a grid of other
        // rows than the area's with no committed still over it is a torn frame.
        if model.isTUI, let fed = feedHostRows, fed != tuiGridHold.rows(page: tuiRows), !(freezeView != nil && heldCommitted) {
            flickerTrace?.countTorn(fed: fed, area: tuiGridHold.rows(page: tuiRows))
        }
        #endif
        // A TUI's screen has no scroll: the held frame goes once the replay drew.
        if model.isTUI, freezeView != nil, heldFrameMayGo() { unfreeze() }
        // The pinned header shows the frame just presented, in this transaction.
        if tuiHeaderRows > 0 { applyTUIHeader() }
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
        guard !holdAwaitsReset else { return false }
        // A newer resize's answer is coming: this replay is not shown.
        guard !newestAnswerAwaited else { return false }
        guard model.isTUI || (placedSinceHold && document != nil && cell.height > 0) else { return false }
        let visible = model.isTUI ? 0..<0 : visibleRowRange
        return TerminalHeldFrame.releasesOnPresent(isAlternate: model.isTUI, replayDrawn: freezeBatches > 0, markPending: restorePending,
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
            if finder.isActive { finder.redraw() }
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
            stopGlide(thenFollow: true)
            copyMode.exit()
            selection.clear()
            scrollView.isScrollEnabled = false
            scrollView.topEdgeEffect.style = .hard
            placesFromReport = false
            statusScrim.isHidden = true
            tuiClip.isHidden = false
            tuiHost.addSubview(surface)
            surface.frame = CGRect(x: 0, y: 0, width: hostLayout.surfaceWidth, height: CGFloat(surfaceRows) * cell.height)
            tuiPanX = 0
            tuiRowShift = 0
            applyTUIPlacement()
            viewportTracker.request(0)
            surface.scroll(toRow: 0)
            scrollButtonVisibility = JumpToBottomVisibility()
            setScrollButton(visible: false)
        } else {
            // The app's screen is gone: its selection and fling go with it.
            tuiSelection.clear()
            tuiScroll.stopMomentum()
            endGridHold(layout: false)
            apply(replayHold.cancel(), pageWide: true)
            scrollView.isScrollEnabled = true
            scrollView.topEdgeEffect.style = .soft
            tuiClip.isHidden = true
            statusScrim.isHidden = false
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
        finder.rowsReplaced()
        // The note follows the screen it is over (letterbox or corner).
        applyHostGridNote()
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

    // Runs on every scroll frame.
    // perf-hot: 1ms
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
        // The letterbox note moves with the rows above it (O(1), no text built).
        positionHostGridNote()
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
        if cell.height > 0 {
            // A rotation's re-wrap keeps the lines being read (the projection).
            let below = max(0, (maxOffsetY - scrollView.contentOffset.y) / cell.height)
            model.session.noteReaderRowsFromEnd(Int(below.rounded() + scrollView.bounds.height / cell.height))
        }
        // The reader moved to within a screen of the oldest row held: a Mac
        // terminal that attached with its latest screen first brings older
        // rows (never for the page's own placement or a short document).
        // A finger on the page asks at once; a fling asks when it ends
        // (`olderRowsWanted`), since the replay's reset would stop it.
        if scrollView.contentOffset.y < -scrollView.contentInset.top + scrollView.bounds.height {
            if scrollView.isTracking {
                model.session.loadOlderHistory()
            } else if scrollView.isDecelerating || fling != nil {
                olderRowsWanted = true
            }
        }
        // The mirror holds a window far above the Mac's screen (a long
        // history): a reader within a screen of where the window ends gets
        // the newer rows, or the newest when they came up from the screen.
        // Not while a reset's replay is fed or the reader's rows are still to
        // be put back: the page's rows then are not the reader's, and a fling
        // up to line 1 moved the window back down 40 times on its way
        // (simulator run 8f9f55310f87a97be78b36cd).
        let gapOffsetY = scrollView.contentOffset.y
        defer { lastGapOffsetY = gapOffsetY }
        if scrollView.isTracking || scrollView.isDecelerating, cell.height > 0,
           !replayGate.isReplaying, !restorePending, let lastY = lastGapOffsetY, gapOffsetY != lastY,
           let windowRows = model.session.historyWindowRows {
            let gap = TerminalHistoryGap(shift: feedHostRows.map { surface.grid.rows - $0 } ?? 0, windowRows: windowRows)
            let minY = max(0, gapOffsetY)
            let top = originRow + Int(floor(minY / cell.height))
            let bottom = originRow + Int(ceil((minY + scrollView.bounds.height) / cell.height))
            if let need = gap.need(visibleTop: top, visibleBottom: bottom, movingDown: gapOffsetY > lastY) {
                let asked = model.session.loadNewerHistory(toTheScreen: need == .newest)
                #if DEBUG
                if asked { TerminalHistoryWindowProbe.shared.note(need == .newest ? "N" : "R") }
                if asked, need == .newest {
                    let probe = TerminalHistoryWindowProbe.shared
                    probe.lastNewest = "\(top)-\(bottom)/gap\(gap.row)/doc\(originRow)-\(document?.endRow ?? -1)/after:\(probe.lastPlace)/\(probeResetContext())"
                }
                #endif
                _ = asked
            }
        }
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
        // The alternate screen's drag is the TUI scroll's (`installTUIScroll`).
        if !model.isTUI { panFrames.begin(.scrollback, rows: documentRows) }
        // A finger owns the offset until it lifts (or the deceleration ends).
        // A restore still waiting for its frame (applyScroll) moves the page
        // to the reader's rows first, so the drag starts there. Before, the
        // drag started on the old offset, the Mac's screen after a history
        // window's replay, and a fling up asked for the newest rows (#43189,
        // step fdef196a3760133107947747: `place=f…@1656/4151`, then
        // `newest=4096-4152/gap4111`).
        if let unplaced = scroll.began(), let document, cell.height > 0, !model.isTUI {
            let y = document.contentY(ofRow: unplaced.row, cellHeight: cell.height) + unplaced.delta
            settingOffset = true
            scrollView.contentOffset.y = min(max(-scrollView.contentInset.top, y), maxOffsetY)
            settingOffset = false
            updateViewport(visibleMinY: scrollView.contentOffset.y)
            #if DEBUG
            TerminalHistoryWindowProbe.shared.note("U")
            #endif
        }
        restoredMark = nil
        dropPendingRestore()
        placesFromReport = false
        // A finger owns the page: a move waiting for its frame is dropped
        // (the next one measures its own wait).
        followAwaitsPresent = false
        awaitStarted = nil
        fling?.stop()
        fling = nil
        stopGlide()
        // A finger caught the fling: it asks for older rows itself if it
        // drags near the top.
        olderRowsWanted = false
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        let pinned = dragPinsToComposer
        dragPin.ended()
        if pinned || !decelerate { panFrames.finish(.scrollback) }
        if pinned {
            // The keyboard drag ended on the prompt.
            scroll.jumpToBottom()
            applyScroll()
        } else if !decelerate {
            settleScroll()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        panFrames.finish(.scrollback)
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
        let olderWanted = olderRowsWanted
        olderRowsWanted = false
        guard !model.isTUI, cell.height > 0 else { return }
        if olderWanted, scrollView.contentOffset.y < -scrollView.contentInset.top + scrollView.bounds.height {
            model.session.loadOlderHistory()
        }
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
        #if DEBUG
        noteTopRowForProbe()
        #endif
    }

    #if DEBUG
    /// The first word of the page's first row with text, for
    /// `TerminalHistoryWindowProbe` (the history demo's rows start with
    /// their number, so a UI test reads which row the reader rests on).
    private func noteTopRowForProbe() {
        guard let document, cell.height > 0 else { return }
        let first = TerminalScrollModel.anchor(offsetY: scrollView.contentOffset.y, layout: document, rowHeight: cell.height).row
        let reader = rowReader
        for row in max(0, first)..<(max(0, first) + max(1, Int(scrollView.bounds.height / cell.height))) {
            guard let text = reader.text(TerminalAbsoluteRow(row)) else { continue }
            if let word = text.split(separator: " ", omittingEmptySubsequences: true).first {
                TerminalHistoryWindowProbe.shared.topWord = String(word)
                return
            }
        }
    }
    #endif

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        // No fling away from the prompt after a pinned dismissal.
        if dragPinsToComposer { targetContentOffset.pointee = scrollView.contentOffset }
    }

    private func setScrollButton(visible requested: Bool) {
        // Following (a Jump to bottom tap, typing) hides the row at once,
        // while the page may still wait for the end's frame: the composer
        // shrinks before the page lands, not in the frames after (qa11 wt-fling-b).
        let visible = requested && !following && glide == nil
        guard model.isScrolledUp != visible else { return }
        model.isScrolledUp = visible
        // The stack's top row shows Jump to bottom (`TerminalJumpToBottomRow`).
        // A hide is laid out now, in this transaction, so the frame that
        // shows the moved rows never still draws the row (round 11 N4: 4 of
        // 250 jumps drew it on the first moved frame; SwiftUI's own pass
        // came one frame later).
        guard !visible, let host = jumpRowHost?.view else { return }
        UIView.performWithoutAnimation {
            host.invalidateIntrinsicContentSize()
            host.setNeedsLayout()
            host.layoutIfNeeded()
            view.layoutIfNeeded()
        }
        updateBottomBacking()
    }

    /// Jump to bottom: one tap lands at the live bottom and follows, whatever
    /// the page is doing (user report 2026-10-14: mid-fling the tap did
    /// nothing, since UIKit's deceleration kept the offset). The deceleration
    /// stops and a drag in progress is cancelled, so nothing else owns the page.
    func scrollToBottom(animated: Bool) {
        dropPendingRestore()
        fling?.stop()
        fling = nil
        stopGlide()
        settingOffset = true
        scrollView.haltScrollMomentum()
        settingOffset = false
        // An animated scroll to the live bottom (CMUX-10: the tap snapped
        // there). Reduce Motion, a TUI or a page already at the bottom keep
        // the direct move.
        if animated, !UIAccessibility.isReduceMotionEnabled, !model.isTUI, cell.height > 0,
           maxOffsetY - scrollView.contentOffset.y > cell.height {
            startGlide()
            return
        }
        scroll.jumpToBottom()
        setScrollButton(visible: false)
        applyScroll()
        #if DEBUG
        sizingLog.notice("scroll: jump to bottom (decelerating \(self.scrollView.isDecelerating, privacy: .public), tracking \(self.scrollView.isTracking, privacy: .public)) -> offset \(Int(self.scrollView.contentOffset.y), privacy: .public) of \(Int(self.maxOffsetY), privacy: .public)")
        #endif
    }

    /// Glides to the live bottom over one short ease-out, per display frame
    /// through the same delegate path as a fling (the rows the page passes
    /// are asked for as it moves). Far up, it starts a glide's length above
    /// the bottom once that frame is drawn, so the page never shows rows it
    /// has not rendered. A drag, typing, find, Scroll to Top, a selection's
    /// autoscroll, a reset or a full-screen app stops it (a tap does not, and
    /// opens no link while it runs); its end follows the bottom, as the
    /// direct jump did.
    private func startGlide() {
        // The page is owned by the glide: no settle, no placement (applyScroll).
        scroll.began()
        let viewport = max(scrollView.bounds.height, 1)
        let animator = BottomGlide(
            scrollView: scrollView,
            bottom: { [weak self] in self?.maxOffsetY ?? 0 },
            maxDistance: viewport * BottomGlide.maxViewports,
            covered: { [weak self] y in self?.targetCovered(y) ?? true },
            prepare: { [weak self] y in self?.updateViewport(visibleMinY: y) })
        animator.onEnd = { [weak self] in
            guard let self, glide === animator else { return }
            glide = nil
            scroll.jumpToBottom()
            // Output during the glide only grew the end (updateDocument);
            // measure it now, as a gesture's end does (settleScroll).
            if measureAfterGesture {
                measureAfterGesture = false
                outputSinceProbe = true
                updateDocument()
            }
            applyScroll()
        }
        glide = animator
        // The pill goes at once: the stack is laid out before the first step,
        // so the glide aims at the bottom without it.
        setScrollButton(visible: false)
        animator.start()
        #if DEBUG
        sizingLog.notice("scroll: jump to bottom, glide from \(Int(self.scrollView.contentOffset.y), privacy: .public) to \(Int(self.maxOffsetY), privacy: .public)")
        #endif
    }

    /// Stops Jump to bottom's glide where it is. The caller sets the state;
    /// `thenFollow` leaves it following first (the glide's own `interacting`
    /// would refuse a reveal: find, Scroll to Top).
    private func stopGlide(thenFollow: Bool = false) {
        guard let animator = glide else { return }
        glide = nil
        animator.cancel()
        if thenFollow { scroll.jumpToBottom() }
    }


    /// DEBUG demo: a fling over a full-screen app, as the wheel (T-SCROLL-12).
    func tuiFling(velocity: CGFloat) {
        tuiScroll.demoFling(velocityY: velocity)
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

    /// DEBUG demo: a fling up from here that runs out half a screen below the
    /// top of the rows held, slowing through the last screen the way a
    /// reader's fling into the top does (`historyfling`). The demo fling
    /// keeps `velocity * 0.998^ms`, so it travels `velocity / 2.002` points.
    func flingToNearTop() {
        let distance = scrollView.contentOffset.y + scrollView.contentInset.top - scrollView.bounds.height / 2
        guard distance > 0 else { return }
        fling(velocity: -distance * 2.002)
    }

    // MARK: Keyboard

    @objc private func tuiTapped(_ tap: UITapGestureRecognizer) {
        // A tap makes this phone the active device (Prefer the active device).
        model.session.noteInteraction()
        // A tap that ends a selection only ends it, as in the shell.
        if selection.selection == nil, tuiSelection.selection == nil, model.isTUI, surface.superview === tuiHost {
            // A touch that is part of scrolling the app is never its click
            // (a thumb flicking a transcript clicked the rows it landed on).
            let verdict = tuiScroll.tapVerdict(at: tap.location(in: tuiClip))
            if verdict == .ignore { return }
            // A link opens unless the app asked for the mouse: then the tap is its click.
            if !surface.capturesMouse, let url = tuiLink(at: tap.location(in: tuiHost)) {
                model.openLink(url)
                return
            }
            if verdict == .click { surface.click(at: tap.location(in: surface)) }
        }
        terminalTapped()
    }

    /// A tap on the shell's rows: a web link opens where it can be reached (a public page on
    /// this iPhone, a dev server on the Mac); anywhere else the terminal takes the keyboard.
    @objc private func shellTapped(_ tap: UITapGestureRecognizer) {
        if !tapStoppedScroll, selection.selection == nil, tuiSelection.selection == nil, !model.isTUI,
           let url = shellLink(at: tap.location(in: scrollView)) {
            model.session.noteInteraction()
            model.openLink(url)
            return
        }
        terminalTapped()
    }

    /// The web link under `point` (scroll view content) on the shell's rows: the tapped
    /// cell's row and the rows a program may have broken the link across.
    private func shellLink(at point: CGPoint) -> URL? {
        guard let document, let cell = selection.cellAt(point),
              selection.rectFor(cell).insetBy(dx: -2, dy: -2).contains(point) else { return nil }
        let first = max(document.originRow, cell.row - TerminalLinkFinder.reach)
        let last = min(document.endRow - 1, cell.row + TerminalLinkFinder.reach)
        guard last >= first else { return nil }
        let reader = rowReader
        let rows = (first...last).map { reader.text(TerminalAbsoluteRow($0)) ?? "" }
        return TerminalLinkFinder(rows: rows, firstRow: first, columns: max(1, surface.grid.columns))
            .link(row: cell.row, column: cell.column)?.url
    }

    /// The web link under `point` (TUI host) on a full-screen app's screen.
    private func tuiLink(at point: CGPoint) -> URL? {
        guard let cell = tuiSelection.cellAt(point), tuiSelection.rectFor(cell).insetBy(dx: -2, dy: -2).contains(point) else { return nil }
        let first = max(0, cell.row - TerminalLinkFinder.reach)
        let last = min(surface.grid.rows - 1, cell.row + TerminalLinkFinder.reach)
        guard last >= first else { return nil }
        let rows = (first...last).map { tuiSelection.rowText($0) ?? "" }
        return TerminalLinkFinder(rows: rows, firstRow: first, columns: max(1, surface.grid.columns))
            .link(row: cell.row, column: cell.column)?.url
    }

    // MARK: Find

    /// Find… (the page menu, Cmd-F).
    func presentFind() {
        copyMode.exit()
        selection.clear()
        tuiSelection.clear()
        finder.present(terminalHadFocus: surface.isFirstResponder)
    }

    private func installFind() {
        // On the surface: the find bar's interaction needs a view that can take the keyboard.
        finder.install(in: surface)
        finder.readRows = { [weak self] in
            guard let self, cell.height > 0 else { return nil }
            let columns = max(1, surface.grid.columns)
            if model.isTUI {
                // A full-screen app: its screen only (it has no scrollback).
                let rows = (0..<max(0, surface.grid.rows)).map { self.tuiSelection.rowText($0) ?? "" }
                return (rows, Array(repeating: false, count: rows.count), 0, columns)
            }
            // The shell: every row the phone holds, scrollback included, numbered like the scrollbar.
            guard let screen = surface.screenRows() else { return nil }
            return (screen.rows, screen.wraps, 0, columns)
        }
        finder.rectFor = { [weak self] point in
            guard let self else { return .zero }
            return model.isTUI ? tuiSelection.rectFor(point) : selection.rectFor(point)
        }
        finder.drawnRows = { [weak self] in
            guard let self else { return 0..<0 }
            if model.isTUI { return 0..<max(0, surface.grid.rows) }
            return presentedTop..<(presentedTop + max(surface.grid.rows, surfaceRows))
        }
        finder.highlightHost = { [weak self] in
            guard let self else { return nil }
            return model.isTUI ? tuiHost : scrollView
        }
        finder.reveal = { [weak self] match in self?.revealFindMatch(match) }
        finder.ended = { [weak self] restoreFocus in
            if restoreFocus { self?.focusTerminal() }
        }
    }

    /// Scrolls the shell so `match` shows, a third of the way down the rows, unless it
    /// shows already. A full-screen app's matches are all on its screen.
    private func revealFindMatch(_ match: TerminalFindResults.Match) {
        reveal(row: match.row)
    }

    /// Scrolls the shell so `row` shows, a third of the way down the rows, unless it shows already.
    private func reveal(row: Int) {
        guard !model.isTUI, let document, cell.height > 0 else { return }
        let rowY = document.contentY(ofRow: row, cellHeight: cell.height)
        let visibleTop = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        let visibleBottom = scrollView.contentOffset.y + scrollView.bounds.height - scrollView.adjustedContentInset.bottom
        if rowY >= visibleTop, rowY + cell.height <= visibleBottom { return }
        let visibleRows = max(1, Int((visibleBottom - visibleTop) / cell.height))
        let top = max(document.originRow, row - visibleRows / 3)
        let topY = document.contentY(ofRow: top, cellHeight: cell.height) - scrollView.adjustedContentInset.top
        fling?.stop()
        fling = nil
        stopGlide(thenFollow: true)
        if topY >= maxOffsetY - 0.5 {
            scroll.jumpToBottom()
        } else {
            // The top row and how far above it the page starts (the top inset at the document's top).
            scroll.reveal(row: top, delta: topY - document.contentY(ofRow: top, cellHeight: cell.height))
        }
        placesFromReport = false
        applyScroll()
    }

    // MARK: Copy Mode, Select All, Scroll to Top

    private func installCopyMode() {
        copyMode.install(in: view, above: bottomStack.topAnchor)
        copyMode.isAvailable = { [weak self] in
            guard let self else { return false }
            return !model.isTUI && document != nil && cell.height > 0
        }
        copyMode.documentRows = { [weak self] in self?.selection.documentRows() ?? 0..<0 }
        copyMode.columns = { [weak self] in max(1, self?.surface.grid.columns ?? 1) }
        copyMode.rowText = { [weak self] row in self?.copyModeRowText(row) ?? "" }
        copyMode.reveal = { [weak self] row in self?.reveal(row: row) }
        copyMode.draw = { [weak self] selection, handles in self?.selection.show(selection, handles: handles) }
        copyMode.text = { [weak self] start, end in self?.selection.text(start, end) }
        copyMode.activeChanged = { [weak self] active in
            self?.model.copyModeActive = active
            if !active { self?.copyModeRows = nil }
        }
        copyMode.ended = { [weak self] restoreFocus in
            if restoreFocus { self?.focusTerminal() }
        }
        selection.selectionChanged = { [weak self] selection in self?.copyMode.selectionChanged(selection) }
    }

    /// A row's text for Copy Mode: the rows Ghostty holds, else the whole screen read once.
    private func copyModeRowText(_ row: Int) -> String {
        if let text = rowReader.text(TerminalAbsoluteRow(row)) { return text }
        let key = [scrollbar.total, scrollbar.offset]
        if copyModeRows?.key != key, let screen = surface.screenRows() { copyModeRows = (key, screen.rows) }
        guard let rows = copyModeRows?.rows, rows.indices.contains(row) else { return "" }
        return rows[row]
    }

    /// Select Text… (the page menu): Copy Mode with the cursor's row selected.
    func presentCopyMode() {
        finder.dismiss()
        tuiSelection.clear()
        copyMode.enter(selectLine: true, terminalHadFocus: surface.isFirstResponder)
    }

    /// The Mac's Toggle Copy Mode (Shift-Cmd-M).
    @objc func toggleCopyMode() {
        guard !copyMode.isActive else { return copyMode.exit() }
        finder.dismiss()
        tuiSelection.clear()
        copyMode.enter(selectLine: false, terminalHadFocus: surface.isFirstResponder)
    }

    /// The Mac's Select All: every row, scrollback included, with Copy in the edit menu
    /// (a full-screen app: its screen).
    func selectAllText() {
        copyMode.exit()
        if model.isTUI { tuiSelection.selectAll() } else { selection.selectAll() }
    }

    /// The Mac's Scroll to Top: the first row the phone holds. The page stops following.
    func scrollToTop() {
        guard !model.isTUI, let document, cell.height > 0 else { return }
        fling?.stop()
        fling = nil
        stopGlide(thenFollow: true)
        scroll.reveal(row: document.originRow, delta: -scrollView.adjustedContentInset.top)
        placesFromReport = false
        applyScroll()
        // Rows older than the phone holds (a projection's window, a Mac
        // terminal attached with its latest screen first): their replay comes
        // back to the top (`restoreReadingMark`).
        topAsked = model.session.loadOlderHistory()
    }

    /// The Mac's Send Text…: a field whose text is typed into the terminal as is, no Return.
    func presentSendText() {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: String(localized: "Send Text"),
                                      message: String(localized: "Typed into the terminal as is, without Return."),
                                      preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = String(localized: "Text")
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.accessibilityIdentifier = "terminal.sendText.field"
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        let send = UIAlertAction(title: String(localized: "Send"), style: .default) { @MainActor [weak self, weak alert] _ in
            guard let text = alert?.textFields?.first?.text else { return }
            self?.model.sendText(text)
        }
        alert.addAction(send)
        alert.preferredAction = send
        present(alert, animated: true)
    }

    override var keyCommands: [UIKeyCommand]? {
        let toggle = UIKeyCommand(title: String(localized: "Toggle Copy Mode"), action: #selector(toggleCopyMode),
                                  input: "m", modifierFlags: [.command, .shift])
        toggle.wantsPriorityOverSystemBehavior = true
        return [toggle]
    }

    // MARK: Find commands

    // The system's Find, Find Next and Find Previous (Cmd-F, Cmd-G, Shift-Cmd-G): the
    // standard responder actions, so the system's own key commands reach the terminal
    // from the surface or the composer.
    override func find(_ sender: Any?) { presentFind() }
    override func findNext(_ sender: Any?) { finder.step(forward: true, terminalHadFocus: surface.isFirstResponder) }
    override func findPrevious(_ sender: Any?) { finder.step(forward: false, terminalHadFocus: surface.isFirstResponder) }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(find(_:)) || action == #selector(findNext(_:)) || action == #selector(findPrevious(_:)) {
            return started
        }
        return super.canPerformAction(action, withSender: sender)
    }

    #if DEBUG
    /// The terminal demo's tap (`-CmuxMobileTerminalDemoToggle tap`): the
    /// handler a tap on the terminal runs.
    func debugTapTerminal() { terminalTapped() }
    #endif

    @objc private func terminalTapped() {
        #if DEBUG
        if CommandLine.arguments.contains("-CmuxMobileTermLog") { NSLog("mobileterm kbd tap t=%.3f first=%d", CACurrentMediaTime(), surface.isFirstResponder ? 1 : 0) }
        #endif
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
            stopGlide()
            placesFromReport = false
            restoredMark = nil
            scroll.began()
        }
        selection.autoscrollEnded = { [weak self] in self?.settleScroll() }
        selection.linkAt = { [weak self] cell in
            guard let self, let document else { return nil }
            let first = max(document.originRow, cell.row - TerminalLinkFinder.reach)
            let last = min(document.endRow - 1, cell.row + TerminalLinkFinder.reach)
            guard last >= first else { return nil }
            let reader = rowReader
            let rows = (first...last).map { reader.text(TerminalAbsoluteRow($0)) ?? "" }
            return TerminalLinkFinder(rows: rows, firstRow: first, columns: max(1, surface.grid.columns))
                .link(row: cell.row, column: cell.column)?.url
        }
        selection.openLink = { [weak self] url, action in self?.model.openLink(url, action: action) }
        selection.otherLinkDevice = { [weak self] url in self?.model.otherLinkDevice(url) }
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
        tuiSelection.linkAt = { [weak self] cell in
            guard let self else { return nil }
            let first = max(0, cell.row - TerminalLinkFinder.reach)
            let last = min(surface.grid.rows - 1, cell.row + TerminalLinkFinder.reach)
            guard last >= first else { return nil }
            let rows = (first...last).map { self.tuiSelection.rowText($0) ?? "" }
            return TerminalLinkFinder(rows: rows, firstRow: first, columns: max(1, surface.grid.columns))
                .link(row: cell.row, column: cell.column)?.url
        }
        tuiSelection.openLink = { [weak self] url, action in self?.model.openLink(url, action: action) }
        tuiSelection.otherLinkDevice = { [weak self] url in self?.model.otherLinkDevice(url) }
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
        tuiScroll.dragBegan = { [weak self] in
            guard let self else { return }
            tuiSelection.clear()
            panFrames.begin(.tui, rows: documentRows)
        }
        tuiScroll.panEnded = { [weak self] in self?.panFrames.finish(.tui) }
        #if DEBUG
        tuiScroll.wheelSent = { [weak self] in self?.rttLog.wheelSent() }
        #endif
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
        #if DEBUG
        if CommandLine.arguments.contains("-CmuxMobileTermLog") { NSLog("mobileterm kbd focus t=%.3f first=%d", CACurrentMediaTime(), surface.isFirstResponder ? 1 : 0) }
        #endif
        model.directTyping = true
        surface.becomeFirstResponder()
    }

    func hideKeyboard() {
        #if DEBUG
        if CommandLine.arguments.contains("-CmuxMobileTermLog") { NSLog("mobileterm kbd hide t=%.3f first=%d", CACurrentMediaTime(), surface.isFirstResponder ? 1 : 0) }
        #endif
        view.window?.endEditing(true)
    }

    @objc private func keyboardWillShow(_ note: Notification) {
        #if DEBUG
        if CommandLine.arguments.contains("-CmuxMobileTermLog") { NSLog("mobileterm kbd willShow t=%.3f first=%d", CACurrentMediaTime(), surface.isFirstResponder ? 1 : 0) }
        startKeyboardProbe(showing: true)
        #endif
        let notified = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .zero
        // In this app's points (an iPhone app on an iPad gets the iPad's keyboard in iPad points).
        let frame = keyboardDock.keyboardFrame(notified: notified, showing: true)
        let screen = view.window?.screen.bounds ?? UIScreen.main.bounds
        dock.keyboardWillShow(visibleHeight: max(0, screen.intersection(frame).height))
        setKeyBar(visible: dock.softKeyboard == .shown, note: note)
        measured("keyboard-will") { keyboardWillMove(note) }
    }

    @objc private func keyboardWillHide(_ note: Notification) {
        #if DEBUG
        if CommandLine.arguments.contains("-CmuxMobileTermLog") { NSLog("mobileterm kbd willHide t=%.3f first=%d", CACurrentMediaTime(), surface.isFirstResponder ? 1 : 0) }
        startKeyboardProbe(showing: false)
        #endif
        dock.keyboardWillHide()
        setKeyBar(visible: false, note: note)
        measured("keyboard-will") { keyboardWillMove(note) }
    }

    @objc private func keyboardDidHide(_ note: Notification) {
        #if DEBUG
        if CommandLine.arguments.contains("-CmuxMobileTermLog") { NSLog("mobileterm kbd didHide t=%.3f first=%d", CACurrentMediaTime(), surface.isFirstResponder ? 1 : 0) }
        #endif
        // A hide a newer show interrupted: the keyboard is on its way up, and
        // settling the stack now would lay it out against the hide.
        guard !isStale(note), !endsOnScreen(note, onScreen: true) else { return }
        #if DEBUG
        settleKeyboardProbe()
        #endif
        dock.keyboardDidHide()
        keyboardStopped()
        keyboardDidChange()
    }

    @objc private func keyboardDidShow(_ note: Notification) {
        // A show a newer hide interrupted (the keyboard key pressed twice).
        guard !isStale(note), !endsOnScreen(note, onScreen: false) else { return }
        #if DEBUG
        settleKeyboardProbe()
        #endif
        keyboardStopped()
        keyboardDidChange()
    }

    /// The tracker forgot a keyboard nothing owns (UIKit never posted its
    /// hide): the dock's guide is already back at rest; the key row's
    /// keyboard glyph, a TUI's rows and the saved frame follow as after a hide.
    private func keyboardDropped() {
        dock.keyboardWillHide()
        dock.keyboardDidHide()
        if model.keyboardVisible { model.keyboardVisible = false }
        // As keyboardDidHide: output held while the keyboard moved goes out.
        keyboardStopped()
        keyboardDidChange()
    }

    /// A did-show or did-hide that ends a transition a later one replaced
    /// (`MobileKeyboardFrameTracker.isStale(didChangeTo:)`).
    private func isStale(_ note: Notification) -> Bool {
        guard let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return false }
        return keyboardTracker.isStale(didChangeTo: end)
    }

    /// A did-show whose end frame is off screen (or a did-hide whose end frame
    /// is on screen) belongs to a transition being reversed. A hide that lands
    /// just after a show's animation, but before UIKit posted its did-show,
    /// gets that did-show with the hide's frame, ahead of the hide's will
    /// (measured: did-show 24 ms past the show's duration, so `isStale` lets it
    /// through). Laying out on it put the composer at the bottom in one frame
    /// while the keyboard was still up; the will that follows moves it inside
    /// the keyboard's animation instead.
    private func endsOnScreen(_ note: Notification, onScreen: Bool) -> Bool {
        guard let notified = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return false }
        let frame = keyboardDock.keyboardFrame(notified: notified)
        let screen = view.window?.screen.bounds ?? UIScreen.main.bounds
        let visible = screen.intersection(frame).height > 0.5
        return visible == onScreen
    }

    /// The keyboard starts to move (will-show, will-hide). Its movement is
    /// tracked for the replay hold (`TerminalKeyboardReplayHold`): a redraw
    /// the Mac sends at fewer rows for another cause (a chrome change) while
    /// the keyboard moves waits for it to stop. Nothing is claimed: the soft
    /// keyboard never resizes the Mac's PTY (`TerminalGridSizing`).
    private func keyboardWillMove(_ note: Notification) {
        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0
        keyboardMovement &+= 1
        if duration > 0 {
            replayHold.keyboardStarted()
            keyboardMoveEnds = CACurrentMediaTime() + duration
            let movement = keyboardMovement
            // A did-show or did-hide that never comes (a reversed transition)
            // ends the movement after its own duration.
            DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.1) { [weak self] in
                guard let self, self.keyboardMovement == movement else { return }
                self.keyboardStopped()
            }
        } else {
            // No animation (a hardware keyboard, an input view reload): the
            // keyboard is at its end already.
            keyboardStopped()
        }
    }

    /// The keyboard reached its end (or a reversal ended its movement): output
    /// held back while it moved (`replayHold`) goes to the screen.
    private func keyboardStopped() {
        apply(replayHold.keyboardStopped())
    }

    /// A keyboard hold ended (`TerminalKeyboardReplayHold.Release`): a reset
    /// behind the held grid gets its held frame now, before its replay is
    /// fed, and the output queue goes on.
    private func apply(_ release: TerminalKeyboardReplayHold.Release, pageWide: Bool = false) {
        if release.takeHeldFrame { freezeLastFrame(pageWide: pageWide) }
        guard release.resume else { return }
        sizingLog.notice("keyboard hold ended: the Mac's redraw at \(self.tuiRows, privacy: .public) rows goes to the screen")
        scheduleOutput()
    }

    @objc private func keyboardDidChange() {
        measured("keyboard-did") { keyboardSettledLayout() }
    }

    /// The keyboard settled. The grid keeps its rows: no PTY resize for the
    /// soft keyboard showing or closing (`TerminalGridSizing`).
    private func keyboardSettledLayout() {
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
    /// The terminal's background (its Mac's terminal theme, `TerminalViewController.terminalBackground`).
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

/// The output pump's work since the screen was made (`outputCounts`).
struct TerminalOutputPumpCounts: Equatable {
    /// Display frames the output link ran on.
    var frameTicks = 0
    /// Calls into the pump (frames, burst wakes, arrivals).
    var pumps = 0
    /// Batches handed to Ghostty.
    var batches = 0
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

/// Where the Mac's grid note goes (`TerminalViewController.applyHostGridNote`).
enum HostGridNoteSpot: Equatable {
    case none
    /// Below a shorter grid: `gridHeight` points under its first row, then `offset`.
    case letterbox(gridHeight: CGFloat, offset: CGFloat)
    /// The compact chip of this size in the terminal area's top-trailing corner.
    case corner(CGSize)
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
        let remoteColumns = TerminalHostGridLayout.followedHostColumns(
            remoteColumns: appliedHostColumns ?? model.session.remoteColumns,
            gridIsPhonesOwn: hostGridIsPhonesOwn, alternateScreen: model.isTUI)
        return TerminalHostGridLayout(viewportWidth: view.bounds.width - 2 * Self.sidePadding, cell: cell,
                                      scale: view.window?.screen.scale ?? surface.renderScale, hostColumns: remoteColumns,
                                      hostRows: remoteColumns == nil ? nil : appliedHostRows ?? model.session.remoteRows,
                                      visibleRows: tuiGridHold.rows(page: tuiRows))
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
    // Runs before every output batch.
    // perf-hot: 0.05ms
    func syncHostGrid() {
        guard cell.width > 0, view.bounds.width > 0 else { return }
        let layout = hostLayout
        // The columns (the mirror's width) or only the rows (the letterbox,
        // the primary screen's pin, the note) changed.
        if layout.surfaceWidth != mirrorWidth || layout.hostRows != laidOutHostRows {
            sizingLog.notice("mirror follows the Mac: \(layout.columns, privacy: .public) columns, \(layout.hostRows ?? -1, privacy: .public) rows (phone \(layout.phoneColumns, privacy: .public), capped \(layout.isCapped, privacy: .public))")
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
            if tuiKeyboardLift != 0 {
                tuiKeyboardLift = 0
                tuiClip.bounds.origin.y = 0
            }
            if tuiHeaderRows != 0 {
                tuiHeaderRows = 0
                applyTUIHeader()
            }
            return
        }
        let layout = hostLayout
        tuiPanX = layout.clampPan(tuiPanX)
        tuiRowShift = layout.rowShift(keeping: surface.cursorViewportRow, from: tuiRowShift)
        let origin = CGPoint(x: -tuiPanX, y: -CGFloat(tuiRowShift) * cell.height)
        if surface.frame.origin != origin {
            UIView.performWithoutAnimation { surface.frame.origin = origin }
        }
        // Keyboard up: the grid's bottom rides the stack and its top is
        // clipped; the app's first rows stay pinned at the top (the top
        // exception) and the body moves down only as far as the cursor's row
        // needs. Set in the layout pass, so inside the keyboard's own animation.
        let placement = TerminalGridSizing(cellHeight: cell.height)
            .keyboardPlacement(gridRows: tuiGridHold.rows(page: tuiRows), visibleHeight: tuiClip.bounds.height,
                               cursorRow: surface.cursorViewportRow.map { $0 - tuiRowShift })
        if placement.lift != tuiKeyboardLift {
            tuiKeyboardLift = placement.lift
            tuiClip.bounds.origin.y = -placement.lift
        }
        tuiHeaderRows = placement.headerRows
        applyTUIHeader()
        positionHostGridNote()
        if finder.isActive { finder.redraw() }
    }

    /// The pinned header (the top exception): `tuiHeaderRows` of the TUI
    /// host's first rows over the top of the area, from the frame the surface
    /// presented last (its layer's IOSurface, cropped by `contentsRect`). A
    /// pointer swap per present, no extra draw. Hidden with no header rows.
    func applyTUIHeader() {
        let rows = tuiHeaderRows
        guard rows > 0, !tuiClip.isHidden, cell.height > 0, surface.superview === tuiHost,
              let frameLayer = surface.layer.sublayers?.first, let contents = frameLayer.contents,
              frameLayer.bounds.width > 0, frameLayer.bounds.height > 0 else {
            if !tuiHeader.isHidden { tuiHeader.isHidden = true }
            tuiHeader.layer.contents = nil
            return
        }
        let width = max(0, tuiClip.frame.width - 2 * Self.sidePadding)
        let height = CGFloat(rows) * cell.height
        let frame = CGRect(x: tuiClip.frame.minX + Self.sidePadding, y: tuiClip.frame.minY, width: width, height: height)
        // The host's first rows, where they would sit unclipped: host point
        // (x, y) is surface point (x, y) - surface.frame.origin, then the
        // presented layer's own point.
        let source = CGRect(x: -surface.frame.minX - frameLayer.frame.minX, y: -surface.frame.minY - frameLayer.frame.minY,
                            width: width, height: height)
        let unit = CGRect(x: source.minX / frameLayer.bounds.width, y: source.minY / frameLayer.bounds.height,
                          width: source.width / frameLayer.bounds.width, height: source.height / frameLayer.bounds.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if tuiHeader.frame != frame { tuiHeader.frame = frame }
        tuiHeader.backgroundColor = surface.backgroundColor
        tuiHeader.layer.contents = contents
        tuiHeader.layer.contentsRect = unit
        let hairline = 1 / (view.window?.screen.scale ?? surface.renderScale)
        tuiHeaderRule.frame = CGRect(x: 0, y: height - hairline, width: width, height: hairline)
        CATransaction.commit()
        if tuiHeader.isHidden { tuiHeader.isHidden = false }
    }

    /// The Mac's grid is the phone's own, as sent or still on its way.
    var hostGridIsPhonesOwn: Bool {
        guard let columns = appliedHostColumns ?? model.session.remoteColumns, let rows = feedHostRows else { return true }
        let grid = TerminalResizeSettle.Size(columns: columns, rows: rows)
        // The grid before the last send is the phone's only while no other
        // device is named as its owner: a named owner's grid that happens to
        // equal the phone's old claim is that device's, not a resize in flight.
        return grid == sentGrid || (hostGridOwner == nil && grid == sentGridBefore)
    }

    /// The primary screen shows the Mac's shorter grid whole at the top: it
    /// has a letterbox, is not the phone's own, and fits above the dock now.
    /// With the keyboard up and less room than the grid, the page follows
    /// the cursor row instead, as without a letterbox
    /// (docs/shared-terminal-sizing.md: it slides up only as far as the cursor needs).
    var pinsHostGrid: Bool {
        guard let box = hostLayout.letterbox, !hostGridIsPhonesOwn else { return false }
        return box.top <= bottomStack.frame.minY - chromeTop + 0.5
    }

    /// The note's text and spot for the Mac's grid and owner now. Runs when
    /// they or the page's layout change, never per frame (it builds text).
    func applyHostGridNote() {
        let layout = hostLayout
        guard cell.height > 0, !hostGridIsPhonesOwn, let note = layout.note(owner: hostGridOwner) else {
            hostGridNoteSpot = .none
            positionHostGridNote()
            return
        }
        let corner = layout.letterbox == nil
        let text = corner ? layout.compactNote ?? note : note
        if hostGridNote.text != text { hostGridNote.text = text }
        if hostGridNote.accessibilityLabel != note { hostGridNote.accessibilityLabel = note }
        // The corner chip sits over the grid's rows: an opaque pill of the
        // terminal background, so the text under it never shows through.
        hostGridNote.textAlignment = corner ? .center : .natural
        // Opaque (visual review of #42422): the rows scroll under it, so it cannot keep to one row;
        // nothing of the text under it may show through, and a hairline marks its edge.
        hostGridNote.backgroundColor = corner ? CmuxMobileGhosttyApp.background : .clear
        hostGridNote.layer.cornerRadius = corner ? 6 : 0
        hostGridNote.layer.borderWidth = corner ? 1 / max(1, traitCollection.displayScale) : 0
        hostGridNote.layer.borderColor = corner ? hostGridNote.textColor.withAlphaComponent(0.35).cgColor : nil
        hostGridNote.clipsToBounds = corner
        let line = ceil(hostGridNote.font.lineHeight)
        if let box = layout.letterbox {
            hostGridNoteSpot = .letterbox(gridHeight: box.top, offset: min(8, max(0, box.height - line) / 2))
        } else {
            let pointSize = hostGridNote.font.pointSize
            if hostGridChipSize?.text != text || hostGridChipSize?.pointSize != pointSize {
                let width = ceil(hostGridNote.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: line)).width)
                hostGridChipSize = (text, pointSize, CGSize(width: width + 12, height: line + 4))
            }
            hostGridNoteSpot = .corner(hostGridChipSize?.size ?? .zero)
        }
        positionHostGridNote()
    }

    /// Places the note from `hostGridNoteSpot`: below the grid's last row,
    /// over no text and above the dock (hidden where it does not fit, e.g.
    /// under the keyboard), or in the terminal area's top-trailing corner.
    /// O(1) and builds nothing: it runs on every scroll frame.
    func positionHostGridNote() {
        let line = ceil(hostGridNote.font.lineHeight)
        let areaTop = model.isTUI ? tuiClip.frame.minY : chromeTop
        let areaBottom = model.isTUI ? min(tuiClip.frame.maxY, bottomStack.frame.minY) : bottomStack.frame.minY
        var frame = CGRect.zero
        switch hostGridNoteSpot {
        case .none:
            break
        case .corner(let size):
            frame = CGRect(x: view.bounds.width - Self.sidePadding - size.width, y: areaTop + 4, width: size.width, height: size.height)
        case .letterbox(let gridHeight, let offset):
            let gridBottom: CGFloat?
            if model.isTUI {
                // The host's top from its constraints (bottom on the clip's
                // bottom, `tuiHeight` tall), not its frame: in the page's
                // layout pass (`layoutTerminal`) the clip is laid out but the
                // host inside it is not yet, so its frame still has the old
                // rows (a page or chrome change sets them) and the note was
                // hidden above the terminal area, never placed again.
                gridBottom = surface.superview === tuiHost
                    // The clip's height, not its bounds' maxY: the keyboard
                    // lift moves the bounds origin, and the host with it.
                    ? tuiClip.convert(CGPoint(x: 0, y: tuiClip.bounds.height - tuiHeight.constant + gridHeight), to: view).y : nil
            } else if let document, cell.height > 0, scrollbar.total > 0 {
                // The Mac's screen is the mirror's last rows: its bottom is
                // the scrollback's end, wherever the document was last measured.
                gridBottom = scrollView.frame.minY + document.contentY(ofRow: scrollbar.total, cellHeight: cell.height) - scrollView.contentOffset.y
            } else {
                gridBottom = nil
            }
            if let gridBottom {
                frame = CGRect(x: Self.sidePadding, y: gridBottom + offset, width: view.bounds.width - 2 * Self.sidePadding, height: line)
            }
        }
        let shown = !frame.isEmpty && frame.minY >= areaTop - 0.5 && frame.maxY <= areaBottom + 0.5
        if hostGridNote.isHidden == shown { hostGridNote.isHidden = !shown }
        if shown, hostGridNote.frame != frame {
            UIView.performWithoutAnimation { hostGridNote.frame = frame }
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

    /// A tap on the shell notes whether it landed on a moving scroll (that tap only stops it).
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === shellTap {
            tapStoppedScroll = fling != nil || glide != nil || scrollView.isDecelerating
        }
        return true
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

/// Jump to bottom's scroll (CMUX-10): from the page's offset to the live
/// bottom over `duration`, ease-out, re-reading the bottom every frame so
/// output that arrives meanwhile is where it lands. Farther than
/// `maxDistance`, it first waits (up to `waitFrames`) for the frame that draws
/// the rows `maxDistance` above the bottom, moves there, then glides.
@MainActor
final class BottomGlide {
    /// The farthest glide, in viewports; a longer scroll starts this far up.
    static let maxViewports: CGFloat = 1.5
    static let duration: CFTimeInterval = 0.32
    static let waitFrames = 8

    private weak var scrollView: UIScrollView?
    private let bottom: () -> CGFloat
    private let covered: (CGFloat) -> Bool
    private let prepare: (CGFloat) -> Void
    private let maxDistance: CGFloat
    private var from: CGFloat = 0
    private var startTime: CFTimeInterval = 0
    private var waitingFor: CGFloat?
    private var waited = 0
    private var link: CADisplayLink?
    var onEnd: (() -> Void)?

    init(scrollView: UIScrollView, bottom: @escaping () -> CGFloat, maxDistance: CGFloat,
         covered: @escaping (CGFloat) -> Bool, prepare: @escaping (CGFloat) -> Void) {
        self.scrollView = scrollView
        self.bottom = bottom
        self.maxDistance = maxDistance
        self.covered = covered
        self.prepare = prepare
    }

    func start() {
        guard let scrollView else { return finish() }
        let current = scrollView.contentOffset.y
        let end = bottom()
        if end - current > maxDistance {
            let entry = end - maxDistance
            waitingFor = entry
            prepare(entry)
        } else {
            from = current
        }
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = .terminal
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// The offset whose rows the glide waits to be drawn before it moves.
    var pendingEntry: CGFloat? { waitingFor }

    /// Stopped by a drag, typing or another scroll: no `onEnd`.
    func cancel() {
        link?.invalidate()
        link = nil
        onEnd = nil
    }

    private func finish() {
        link?.invalidate()
        link = nil
        let end = onEnd
        onEnd = nil
        end?()
    }

    /// Ease-out cubic: fast off the mark, settling onto the bottom.
    static func progress(elapsed: CFTimeInterval, duration: CFTimeInterval) -> CGFloat {
        let t = CGFloat(min(max(elapsed / duration, 0), 1))
        return 1 - pow(1 - t, 3)
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let scrollView else { return finish() }
        if let entry = waitingFor {
            guard covered(entry) || waited >= Self.waitFrames else {
                waited += 1
                return
            }
            waitingFor = nil
            scrollView.contentOffset.y = entry
            from = entry
            startTime = link.targetTimestamp
            return
        }
        if startTime == 0 { startTime = link.timestamp }
        let p = Self.progress(elapsed: link.targetTimestamp - startTime, duration: Self.duration)
        let end = bottom()
        scrollView.contentOffset.y = from + (end - from) * p
        if p >= 1 { finish() }
    }
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
