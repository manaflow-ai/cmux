#if os(iOS)
import CmuxMobileDesign
import CmuxMobileSupport
import QuartzCore
import SwiftUI
import UIKit

/// Where the agent chat's bottom stack (composer, permission bar) lives.
enum ChatDockPlacement {
    /// The controller hosts the stack, pinned to the keyboard layout guide
    /// (the pushed chat).
    case owned
    /// Someone else draws the stack (a workspace tab's TabsKit accessory).
    /// It rides the keyboard from its resting place; the surface reports its
    /// height and resting bottom, and the transcript follows the keyboard
    /// layout guide itself so the two move in the same animation.
    case external
}

/// Scrolls the transcript on the surface's behalf (jump to bottom, demos).
@MainActor
protocol ChatTranscriptScrolling: AnyObject {
    func scrollTranscript(toTop: Bool, animated: Bool)
    /// Find in Chat: brings content y `y` (the transcript's own coordinates) under the header
    /// and the find bar, and stops following the newest turn.
    func scrollTranscript(toContentY y: CGFloat, animated: Bool)
    /// Find in Chat: brings the transcript row that draws the block `findBlock` (an
    /// `AgentChatFind` key) under the header, at `position` (0...1) of its height.
    func revealFindBlock(_ findBlock: String, position: Double, animated: Bool)
}

/// The agent chat transcript as a UIKit scroll view with a keyboard-docked
/// composer, the way Messages, Telegram and ChatGPT behave:
///
/// - The composer's bottom is constrained to `keyboardLayoutGuide` (8 pt above
///   the keyboard, or 8 pt above the bottom safe area), so UIKit moves it in
///   the keyboard's own animation and with the finger during an interactive
///   dismissal.
/// - The transcript's bottom content inset is the composer's top, recomputed
///   in the same layout pass. A reader at the bottom stays there: the content
///   offset changes with the inset, so the newest turn rides the composer and
///   the top of the transcript is what gets covered. A reader scrolled up
///   stays where they are.
/// - Short content (and the empty state) sits at the bottom / centers in the
///   space between the header and the composer.
/// - `keyboardDismissMode = .interactive`: dragging the transcript down past
///   the composer pulls the keyboard down with the finger.
///
/// SwiftUI's `ScrollView` + `.safeAreaInset` kept the content offset when the
/// keyboard came up, so the keyboard covered the bottom of the transcript
/// instead (user report, iOS 27 device).
@MainActor
final class ChatTranscriptController: UIViewController, UIScrollViewDelegate, ChatTranscriptScrolling {
    let placement: ChatDockPlacement
    let surface: AgentChatSurface
    var topInset: CGFloat? { didSet { if oldValue != topInset { view.setNeedsLayout() } } }
    var onUserScroll: ((CGFloat) -> Void)?

    /// The transcript: a collection view of reused rows (`ChatTranscriptList`).
    private let list: ChatTranscriptList
    private var scrollView: ChatTranscriptCollectionView { list.collectionView }
    /// Workspace chats have no navigation bar to provide a native top edge.
    private let topShelf = UIView()
    /// Like the embedded terminal, iOS 26 also needs a gradient fallback:
    /// a bare top edge container alone does not obscure text under the clock.
    private let topFade = TopFadeView()
    private let emptyHost: UIHostingController<AnyView>
    private var dockHost: UIHostingController<AnyView>?
    private var dockContainer: PassthroughView?
    /// The owned stack's host height: room for the tallest stack (queue,
    /// suggestions, an 8-line field, attachments).
    static let dockHostHeight: CGFloat = 640
    private var jumpHost: UIHostingController<AnyView>?
    /// The bottom stack's frame (the hosted dock, or the external stack's
    /// computed place).
    private let dockGuide = UILayoutGuide()
    private let openArea = UILayoutGuide()
    private var openAreaTop: NSLayoutConstraint?
    private var dockHeightConstraint: NSLayoutConstraint?
    private var externalRestBottom: NSLayoutConstraint?
    private var externalRestBottomMax: NSLayoutConstraint?
    private var contentHeight: CGFloat = 0
    /// The stack's measured height (the guide's height follows it).
    private var stackHeight: CGFloat = 96
    private var positionedInitially = false
    private var shownIdentity: ObjectIdentifier?
    private var keyboardPin: NSLayoutConstraint?
    private var fallbackPin: NSLayoutConstraint?
    private let notifiedKeyboard = UILayoutGuide()
    /// Offset of the notified keyboard's top from the view's bottom (<= 0).
    private var notifiedKeyboardTop: NSLayoutConstraint?
    private var dragLink: CADisplayLink?
    /// The keyboard layout guide did not move with a docked keyboard: seen
    /// on the iOS 27.0 simulator (24A434), where the guide stayed at the
    /// bottom edge for this transcript and for Chief's conversation while
    /// SwiftUI's keyboard inset moved. From then on the stack follows the
    /// keyboard's notifications (inside their animation) and, while a drag
    /// dismisses the keyboard, its drawn frame every display frame.
    private static var layoutGuideStalls = false
    private var lastOffsetY: CGFloat = 0
    /// The jump button's rule (clamped distance, hysteresis; see
    /// `JumpToBottomVisibility`).
    private var jumpVisibility: JumpToBottomVisibility
    /// The jump circle's host size: fixed, so the host never resizes when the
    /// button appears (a hosting view that grew from its empty size inside a
    /// layout animation flew the circle in from the host's old frame).
    static let jumpHostSize: CGFloat = 44
    /// The external stack's bottom with the keyboard down, view coordinates.
    private var externalRest: CGFloat?
    /// A disclosure the person tapped is opening or closing (`holdForDisclosure`): until its
    /// animation completes, the tapped line stays where it is drawn.
    private var foldHolding = false
    /// A safety cap on the hold, should the animation's completion never come (a view torn down
    /// mid-animation). The hold normally ends on that completion (`toggleDisclosure`).
    private var foldHoldCap: Task<Void, Never>?
    static let foldHoldCapSeconds: Double = 1.5
    #if DEBUG
    private var trace: ChatKeyboardTrace?
    #endif

    /// Gap between the stack and the keyboard (or the bottom safe area).
    static let dockGap: CGFloat = 8
    /// Space between the last turn and the stack.
    static let contentGap: CGFloat = 8

    init(placement: ChatDockPlacement, surface: AgentChatSurface, store: AgentChatStore,
         empty: AnyView, dock: AnyView?, jump: AnyView?) {
        self.placement = placement
        self.surface = surface
        list = ChatTranscriptList(store: store, surface: surface)
        emptyHost = UIHostingController(rootView: empty)
        if dock != nil { dockHost = UIHostingController(rootView: AnyView(EmptyView())) }
        if let jump { jumpHost = UIHostingController(rootView: jump) }
        jumpVisibility = JumpToBottomVisibility(isShown: surface.showJump)
        shownIdentity = ObjectIdentifier(store)
        super.init(nibName: nil, bundle: nil)
        list.collectionView.didLayout = { [weak self] in self?.transcriptLaidOut() }
        // A tapped disclosure in a row holds its line while it opens or closes (DisclosureReveal).
        list.context.foldHold = TranscriptFoldHold(
            begin: { [weak self] in self?.holdForDisclosure() },
            end: { [weak self] in self?.endFoldHold() }
        )
        if let dock {
            dockHost?.rootView = Self.measuring(dock, alignment: .bottom) { _ in }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Wraps hosted SwiftUI so it takes its ideal height at the proposed width
    /// and reports it; the host's height constraint follows. (A hosting
    /// controller's intrinsic size is measured without a width, which is wrong
    /// for wrapping text.)
    private static func measuring(_ view: AnyView, alignment: Alignment, report: @escaping (CGFloat) -> Void) -> AnyView {
        AnyView(
            ProposedWidthLayout {
                view.rowHeightProbe("root")
            }
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                    #if DEBUG
                    if RowHeightProbe.isEnabled { RowHeightProbe.log("report \(height)") }
                    #endif
                    report(height)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        )
    }

    /// The rows' environment (open a diff or a file, attachments, links).
    var rowContext: ChatRowContext { list.context }

    /// The hosted views observe the store and the surface themselves, so
    /// their roots are set once: replacing a root on every update put each
    /// change in a fresh, unanimated transaction (the composer's collapse
    /// snapped instead of animating).
    /// `store`: the store the transcript shows. A different store (the tab's
    /// session was replaced) sets the roots again.
    func update(store: AgentChatStore, empty: AnyView, dock: AnyView?, jump: AnyView?) {
        let identity = ObjectIdentifier(store)
        if let shown = shownIdentity, shown != identity {
            endFoldHold(force: true)
            list.show(store: store)
            emptyHost.rootView = empty
            if let dock {
                dockHost?.rootView = Self.measuring(dock, alignment: .bottom) { _ in }
            }
            if let jump { jumpHost?.rootView = jump }
            positionedInitially = false
            surface.following = true
        }
        shownIdentity = identity
        jumpHost?.view.isUserInteractionEnabled = surface.showJump
        if placement == .external { externalMetricsChanged() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        // Docked keyboards only. With `followsUndockedKeyboard` the guide
        // never left the bottom edge on iOS 27 (the composer stayed behind
        // the keyboard); iOS 26 tracked either way.
        view.keyboardLayoutGuide.followsUndockedKeyboard = false
        view.keyboardLayoutGuide.usesBottomSafeArea = false
        view.addLayoutGuide(dockGuide)
        view.addLayoutGuide(openArea)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.keyboardDismissMode = .interactive
        scrollView.alwaysBounceVertical = true
        scrollView.backgroundColor = .cmuxMobileBackground
        scrollView.topEdgeEffect.style = .soft
        list.scrollDelegate = self
        view.addSubview(scrollView)
        setContentScrollView(scrollView, for: .top)

        if placement == .external {
            topShelf.isUserInteractionEnabled = false
            view.addSubview(topShelf)
            let topEdge = UIScrollEdgeElementContainerInteraction()
            topEdge.scrollView = scrollView
            topEdge.edge = .top
            topShelf.addInteraction(topEdge)
            if #unavailable(iOS 27) {
                topFade.isUserInteractionEnabled = false
                topFade.isAccessibilityElement = false
                view.addSubview(topFade)
            }
        }

        for host in [emptyHost] + [dockHost, jumpHost].compactMap({ $0 }) {
            addChild(host)
            host.safeAreaRegions = []
            host.view.backgroundColor = .clear
            host.view.translatesAutoresizingMaskIntoConstraints = false
        }
        emptyHost.sizingOptions = [.intrinsicContentSize]

        view.addSubview(emptyHost.view)
        emptyHost.view.isUserInteractionEnabled = false

        let openTop = openArea.topAnchor.constraint(equalTo: view.topAnchor)
        openAreaTop = openTop
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dockGuide.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dockGuide.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            openTop,
            openArea.bottomAnchor.constraint(equalTo: dockGuide.topAnchor),
            openArea.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            openArea.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyHost.view.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyHost.view.centerYAnchor.constraint(equalTo: openArea.centerYAnchor),
            emptyHost.view.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -40),
        ])

        // Above a docked keyboard (the guide's top is the view's bottom when
        // it is hidden). With a hardware keyboard the guide can report a
        // 0-wide 44 pt frame near the top of the screen (the terminal's
        // composer jumped there, feat-cnx-ios-e2e); `keyboardPinApplies`
        // switches the pin off for such a frame and the stack rests.
        let pin = dockGuide.bottomAnchor.constraint(lessThanOrEqualTo: view.keyboardLayoutGuide.topAnchor, constant: -Self.dockGap)
        pin.isActive = !Self.layoutGuideStalls
        keyboardPin = pin
        // The same pin against the keyboard's frame from its notifications,
        // for when the layout guide stalls (see `layoutGuideStalls`).
        view.addLayoutGuide(notifiedKeyboard)
        let notifiedTop = notifiedKeyboard.topAnchor.constraint(equalTo: view.bottomAnchor)
        notifiedKeyboardTop = notifiedTop
        let fallback = dockGuide.bottomAnchor.constraint(lessThanOrEqualTo: notifiedKeyboard.topAnchor, constant: -Self.dockGap)
        fallback.isActive = Self.layoutGuideStalls
        fallbackPin = fallback
        NSLayoutConstraint.activate([
            notifiedTop,
            notifiedKeyboard.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            notifiedKeyboard.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            notifiedKeyboard.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        switch placement {
        case .owned:
            guard let hosted = dockHost?.view else { break }
            // A tall, transparent host whose bottom rides the keyboard: the
            // stack grows and shrinks inside it on its own (SwiftUI)
            // animation, so UIKit only ever translates it and the card's
            // bottom stays exactly on the host's. Touches on the empty part
            // fall through to the transcript.
            let dock = PassthroughView()
            dock.translatesAutoresizingMaskIntoConstraints = false
            dock.addSubview(hosted)
            view.addSubview(dock)
            dockContainer = dock
            dock.interactiveHeight = 96
            let height = dockGuide.heightAnchor.constraint(equalToConstant: 96)
            dockHeightConstraint = height
            let rest = dock.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -Self.dockGap)
            rest.priority = .defaultLow
            NSLayoutConstraint.activate([
                hosted.topAnchor.constraint(equalTo: dock.topAnchor),
                hosted.bottomAnchor.constraint(equalTo: dock.bottomAnchor),
                hosted.leadingAnchor.constraint(equalTo: dock.leadingAnchor),
                hosted.trailingAnchor.constraint(equalTo: dock.trailingAnchor),
                dock.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                dock.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                dock.heightAnchor.constraint(equalToConstant: Self.dockHostHeight),
                dock.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -Self.dockGap),
                rest,
                height,
                dockGuide.bottomAnchor.constraint(equalTo: dock.bottomAnchor),
            ])
            // A downward swipe on the composer takes the keyboard down too.
            let pan = UIPanGestureRecognizer(target: self, action: #selector(dockPanned(_:)))
            pan.cancelsTouchesInView = false
            pan.delegate = DockPanDelegate.shared
            dock.addGestureRecognizer(pan)
        case .external:
            let height = dockGuide.heightAnchor.constraint(equalToConstant: 96)
            dockHeightConstraint = height
            let restMax = dockGuide.bottomAnchor.constraint(lessThanOrEqualTo: view.topAnchor, constant: 0)
            let rest = dockGuide.bottomAnchor.constraint(equalTo: view.topAnchor, constant: 0)
            rest.priority = .defaultLow
            externalRestBottom = rest
            externalRestBottomMax = restMax
            NSLayoutConstraint.activate([height, restMax, rest])
        }

        if let jump = jumpHost?.view {
            view.addSubview(jump)
            jump.isUserInteractionEnabled = surface.showJump
            NSLayoutConstraint.activate([
                jump.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                jump.bottomAnchor.constraint(equalTo: dockGuide.topAnchor, constant: -8),
                jump.widthAnchor.constraint(equalToConstant: Self.jumpHostSize),
                jump.heightAnchor.constraint(equalToConstant: Self.jumpHostSize),
            ])
        }
        for host in [emptyHost] + [dockHost, jumpHost].compactMap({ $0 }) { host.didMove(toParent: self) }

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(keyboardWillChangeFrame(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        surface.scroller = self
        surface.stackHeightFrame = { [weak self] in self?.stackHeightFrame($0) }
        if let height = surface.drawnStackHeight { stackHeightFrame(height) }
        if placement == .external { externalMetricsChanged() }
        #if DEBUG
        if ChatKeyboardTrace.isEnabled { trace = ChatKeyboardTrace(owner: self) }
        #endif
    }

    /// A keyboard frame worth following: as wide as the view and touching
    /// its bottom (a docked software keyboard, or the guide at rest).
    private var keyboardPinApplies: Bool {
        let frame = view.keyboardLayoutGuide.layoutFrame
        return frame.width >= view.bounds.width - 1 && frame.maxY >= view.bounds.maxY - 1
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // The push has landed: warm the rows' first draws now, not under the push animation.
        list.allowWarmUp()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        list.boundsMayHaveChanged()
        if let pin = keyboardPin, !Self.layoutGuideStalls, pin.isActive != keyboardPinApplies {
            pin.isActive = keyboardPinApplies
            view.setNeedsLayout()
            view.layoutIfNeeded()
            return
        }
        let top = headerBottom
        if openAreaTop?.constant != top { openAreaTop?.constant = top }
        updateStackCeiling(headerBottom: top)
        scrollView.edgeTopInset = top
        if placement == .external {
            let chromeFrame = CGRect(x: 0, y: 0, width: view.bounds.width, height: top)
            if topShelf.frame != chromeFrame { topShelf.frame = chromeFrame }
            if topFade.superview != nil, topFade.frame != chromeFrame { topFade.frame = chromeFrame }
        }

        // As in Messages, a transcript drag takes the keyboard once the finger
        // reaches the stack's top edge.
        let padding = max(0, dockGuide.layoutFrame.height + Self.dockGap)
        if abs(view.keyboardLayoutGuide.keyboardDismissPadding - padding) > 0.5 {
            view.keyboardLayoutGuide.keyboardDismissPadding = padding
        }
        updateInsets()
    }

    // MARK: Insets and position

    /// SwiftUI can consume the safe area before forwarding it to this full-screen
    /// controller. Resolve visible chrome in our coordinates as well, so neither
    /// a pushed chat nor a workspace page can start above the clock or title.
    private var headerBottom: CGFloat {
        var top = max(topInset ?? 0, view.safeAreaInsets.top)
        if let window = view.window {
            let safeTop = view.convert(CGPoint(x: 0, y: window.safeAreaInsets.top), from: window).y
            top = max(top, safeTop)
        }
        if placement == .owned, let navigation = navigationController, !navigation.isNavigationBarHidden {
            let bar = navigation.navigationBar
            top = max(top, view.convert(bar.bounds, from: bar).maxY)
        }
        return max(0, top)
    }

    /// The bottom stack's ceiling (window y) for the composer's slash-command list: under
    /// the header, and for the pushed chat inside the dock's host, which draws nothing and
    /// takes no touch past its top. The dock measures its stack at its ideal height and
    /// proposes no height, so the list bounds itself by this.
    private func updateStackCeiling(headerBottom: CGFloat) {
        guard view.window != nil else { return }
        var top = headerBottom + Self.contentGap
        if let dock = dockContainer { top = max(top, dock.frame.minY) }
        let ceiling = view.convert(CGPoint(x: 0, y: top), to: nil).y
        if surface.stackCeiling.map({ abs($0 - ceiling) > 0.5 }) ?? true { surface.stackCeiling = ceiling }
    }

    /// The stack's top is its bottom (which only the keyboard or the
    /// resting place moves) less its height as drawn this frame.
    private var bottomInset: CGFloat {
        max(0, view.bounds.maxY - (dockGuide.layoutFrame.maxY - stackHeight)) + Self.contentGap
    }

    private var bottomOffset: CGPoint {
        let inset = scrollView.contentInset
        // The content's own height: the scroll view's content size updates
        // only when it lays out, after this controller's layout pass.
        return CGPoint(x: 0, y: max(-inset.top, contentHeight + inset.bottom - view.bounds.height))
    }

    private var distanceFromBottom: CGFloat {
        bottomOffset.y - scrollView.contentOffset.y
    }

    /// The distance from the bottom with the rubber band clamped off: a
    /// pull past either end is not a scroll away from the newest turn.
    private var scrolledDistanceFromBottom: CGFloat {
        JumpToBottomVisibility.distance(offsetY: scrollView.contentOffset.y,
                                        minOffsetY: -scrollView.contentInset.top, maxOffsetY: bottomOffset.y)
    }

    /// The finger is pulling a docked keyboard down (an interactive
    /// dismissal): it reached the stack, where UIKit hands the drag to the
    /// keyboard (`keyboardDismissPadding`).
    private var keyboardDragging: Bool {
        guard scrollView.isTracking else { return false }
        let keyboardTop = Self.layoutGuideStalls
            ? view.bounds.maxY + (notifiedKeyboardTop?.constant ?? 0)
            : view.keyboardLayoutGuide.layoutFrame.minY
        guard keyboardTop < view.bounds.maxY - 1 else { return false }
        return scrollView.panGestureRecognizer.location(in: view).y >= dockGuide.layoutFrame.minY
    }

    /// Insets from the header and the stack; content shorter than the space
    /// between them sits on the stack. Called in every layout pass, so inside
    /// the keyboard's animation when the keyboard moves the stack.
    private func updateInsets() {
        guard view.bounds.height > 0 else { return }
        let bottom = bottomInset
        let headerBottom = self.headerBottom
        let visible = view.bounds.height - headerBottom - bottom
        let top = max(headerBottom, headerBottom + visible - contentHeight)
        if foldHolding {
            holdFoldLine(top: top, bottom: bottom, headerBottom: headerBottom)
            return
        }
        let old = scrollView.contentInset
        let bottomDelta = positionedInitially ? bottom - old.bottom : 0
        if old.top != top || old.bottom != bottom {
            // Resting on the newest turn counts as following it (an
            // interactive dismissal drags the content away mid-gesture, then
            // it settles back).
            if !scrollView.isTracking, !scrollView.isDecelerating, positionedInitially, abs(distanceFromBottom) < 2,
               surface.find?.currentMatch == nil {
                surface.following = true
            }
            scrollView.contentInset = UIEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
            scrollView.verticalScrollIndicatorInsets = UIEdgeInsets(top: headerBottom, left: 0, bottom: bottom, right: 0)
        }
        guard !scrollView.isTracking else { return }
        if !positionedInitially, contentHeight > 0 || surfaceIsEmpty {
            positionedInitially = true
            scrollView.contentOffset = bottomOffset
        } else if positionedInitially, surface.following {
            // Inside the keyboard's animation: the newest turn rides the
            // stack frame by frame and the top of the transcript is covered.
            if scrollView.contentOffset != bottomOffset { scrollView.contentOffset = bottomOffset }
        } else if positionedInitially {
            // A reader scrolled up keeps the bottom of what they see on the
            // stack too (Telegram): the stack rising covers the top instead.
            var offset = scrollView.contentOffset
            offset.y = min(max(-top, offset.y + bottomDelta), bottomOffset.y)
            if offset != scrollView.contentOffset { scrollView.contentOffset = offset }
        }
        lastOffsetY = scrollView.contentOffset.y
        updateJump()
    }

    /// No turns yet (the empty state shows).
    var isEmpty = false {
        didSet {
            guard oldValue != isEmpty, isViewLoaded else { return }
            view.setNeedsLayout()
            if isEmpty { updateJump() }
        }
    }
    private var surfaceIsEmpty: Bool { isEmpty }

    /// After each layout pass of the transcript: rows it measured may have changed the
    /// content height, so the content is placed against the stack again in the same pass
    /// (a following reader stays on the newest row while it streams).
    private func transcriptLaidOut() {
        let height = list.layout.contentHeight
        guard abs(height - contentHeight) > 0.25 else { return }
        contentHeight = height
        // While a disclosure is held, the offset may glide into range on the disclosure's
        // spring (`holdFoldLine`), so that pass is not inside performWithoutAnimation.
        if foldHolding { updateInsets() } else { UIView.performWithoutAnimation { updateInsets() } }
    }

    // MARK: Disclosures

    /// A disclosure in the transcript was tapped (a tool group, a tool call, a thought): its line
    /// stays where it is drawn while the body opens or closes under it, as in ChatGPT. Opening
    /// pushes what is below down, so a reader on the newest row stops following it (the jump
    /// button shows); closing at the end lets the rows above come down with the same spring.
    func holdForDisclosure() {
        guard isViewLoaded, positionedInitially, !scrollView.isTracking else { return }
        foldHolding = true
        surface.following = false
        foldHoldCap?.cancel()
        // A bounded safety cap only; the animation's completion ends the hold.
        foldHoldCap = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.foldHoldCapSeconds))
            guard !Task.isCancelled else { return }
            self?.endFoldHold()
        }
    }

    /// `force`: the reader's own scroll (a drag, Jump to latest, Find) or a new session: their
    /// intent, so the hold lets go at once instead of waiting for the list to show the change.
    func endFoldHold(force: Bool = false) {
        guard foldHolding else { return }
        // The change shows before the line lets go: a native line's tap animates nothing in SwiftUI,
        // so its animation can complete before the list's observation has reloaded the row, and a
        // following chat would then re-pin to its newest row when the row grows. The reload runs on
        // the next turn of the main queue (after that observation's), never inside a layout pass.
        if !force, list.disclosuresPending {
            Task { @MainActor [weak self] in
                self?.list.reloadIfDisclosuresChanged()
                self?.endFoldHold()
            }
            return
        }
        foldHolding = false
        foldHoldCap?.cancel()
        foldHoldCap = nil
        view.setNeedsLayout()
        UIView.performWithoutAnimation { view.layoutIfNeeded() }
        guard !scrollView.isTracking, !scrollView.isDecelerating, surface.find?.currentMatch == nil else { return }
        // Resting on the newest row follows it again. Otherwise the view stays where the reader
        // put it: an open pushed the newest row down, or one streamed in meanwhile, and the jump
        // button shows (as the Mac transcript does, foldAnchor.ts). Snapping back here would
        // move the line the reader just opened.
        if abs(distanceFromBottom) < 2 {
            surface.following = true
        }
    }

    /// The hold's layout pass: no following and no snap. A keyboard that moves meanwhile (a tap
    /// that dismisses it) keeps the line too; the offset only stays in range. Only when the change leaves the view
    /// past what the content now allows (a body closing at the end, a short chat that sits on the
    /// stack) does the offset glide into range, on the disclosure's spring.
    private func holdFoldLine(top: CGFloat, bottom: CGFloat, headerBottom: CGFloat) {
        let lowest = -top
        let highest = max(lowest, contentHeight + bottom - view.bounds.height)
        let y = scrollView.contentOffset.y
        let target = min(max(lowest, y), highest)
        if abs(target - y) > 0.5 {
            // The model offset is the target at once, so the insets below never clamp it.
            if UIAccessibility.isReduceMotionEnabled {
                scrollView.contentOffset.y = target
            } else {
                UIView.animate(springDuration: 0.35, bounce: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                    self.scrollView.contentOffset.y = target
                }
            }
        }
        let insets = UIEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        if scrollView.contentInset != insets {
            scrollView.contentInset = insets
            scrollView.verticalScrollIndicatorInsets = UIEdgeInsets(top: headerBottom, left: 0, bottom: bottom, right: 0)
        }
        lastOffsetY = scrollView.contentOffset.y
        updateJump()
    }

    /// The stack's height as drawn this frame, from the stack itself
    /// (`AgentChatBottomStack` reports it through an animatable modifier on
    /// the composer's spring, once per rendered frame). The transcript's
    /// inset and offset are set in the same SwiftUI update that draws the
    /// stack at that height, so the two land in the same frame; UIKit
    /// timing never has to match SwiftUI's.
    private func stackHeightFrame(_ height: CGFloat) {
        guard abs(stackHeight - height) > 0.01 else { return }
        stackHeight = height
        dockContainer?.interactiveHeight = height
        dockHeightConstraint?.constant = height
        view.setNeedsLayout()
        UIView.performWithoutAnimation { updateInsets() }
    }

    /// The external stack's height and resting bottom from the surface.
    private func externalMetricsChanged() {
        guard placement == .external, isViewLoaded else { return }
        // The stack's bottom is reported in screen space; with the keyboard
        // down it is the resting place (TabsKit puts it above its toolbar).
        if let maxY = surface.stackMaxY, !surface.composerFocused, view.window != nil {
            let rest = view.convert(CGPoint(x: 0, y: maxY), from: nil).y
            if externalRest != rest {
                externalRest = rest
                externalRestBottom?.constant = rest
                externalRestBottomMax?.constant = rest
                view.setNeedsLayout()
            }
        } else if externalRest == nil {
            let rest = view.bounds.height - 72 - Self.dockGap
            externalRestBottom?.constant = rest
            externalRestBottomMax?.constant = rest
        }
    }

    // MARK: Keyboard

    @objc private func keyboardWillChangeFrame(_ note: Notification) {
        // UIKit posts this inside the keyboard's animation. Ending an
        // interactive dismissal moves the guide but lays out later, outside
        // the animation; laying out now rides the keyboard's remaining curve
        // instead of jumping.
        let top = notifiedTop(note)
        notifiedKeyboardTop?.constant = top - view.bounds.maxY
        view.setNeedsLayout()
        let remaining = UIView.inheritedAnimationDuration
        let layout = {
            self.view.layoutIfNeeded()
            // A docked keyboard the guide did not follow: switch to the
            // notified frame, in this same animation.
            if !Self.layoutGuideStalls, top < self.view.bounds.maxY - 40,
               self.view.keyboardLayoutGuide.layoutFrame.minY > top + 40 {
                Self.layoutGuideStalls = true
                self.keyboardPin?.isActive = false
                self.fallbackPin?.isActive = true
                self.view.setNeedsLayout()
                self.view.layoutIfNeeded()
            }
        }
        guard remaining > 0 else {
            layout()
            return
        }
        UIView.animate(withDuration: remaining, delay: 0, options: [.beginFromCurrentState]) { layout() }
    }

    /// The keyboard's top in this view from a frame notification (the
    /// view's bottom when it hides or is not docked).
    private func notifiedTop(_ note: Notification) -> CGFloat {
        guard let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue,
              let window = view.window else { return view.bounds.maxY }
        let frame = view.convert(end, from: window.screen.coordinateSpace)
        guard frame.height > 0, frame.width >= view.bounds.width - 1, frame.maxY >= view.bounds.maxY - 1 else { return view.bounds.maxY }
        return min(view.bounds.maxY, frame.minY)
    }

    /// While the guide stalls and a drag dismisses the keyboard, the stack
    /// follows the keyboard as drawn, every display frame.
    private func followDraggedKeyboard(_ on: Bool) {
        guard Self.layoutGuideStalls, on != (dragLink != nil) else { return }
        if on {
            let link = CADisplayLink(target: DragLinkTarget(self), selector: #selector(DragLinkTarget.tick))
            link.add(to: .main, forMode: .common)
            dragLink = link
        } else {
            dragLink?.invalidate()
            dragLink = nil
        }
    }

    fileprivate func draggedKeyboardFrame() {
        guard scrollView.isTracking, let top = MobileKeyboardProbe().drawnTop(in: view.window) else { return }
        let local = view.convert(CGPoint(x: 0, y: top), from: nil).y
        let constant = min(local, view.bounds.maxY) - view.bounds.maxY
        guard let constraint = notifiedKeyboardTop, abs(constraint.constant - constant) > 0.01 else { return }
        constraint.constant = constant
        UIView.performWithoutAnimation { view.layoutIfNeeded() }
    }

    @objc private func dockPanned(_ pan: UIPanGestureRecognizer) {
        guard pan.state == .changed else { return }
        let t = pan.translation(in: view)
        if t.y > 14, t.y > abs(t.x) * 1.5 {
            surface.composerFocused = false
            view.endEditing(true)
            pan.isEnabled = false
            pan.isEnabled = true
        }
    }

    // MARK: Scrolling

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        // The person's own scroll ends a disclosure's hold.
        endFoldHold(force: true)
        followDraggedKeyboard(true)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { followDraggedKeyboard(false) }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let y = scrollView.contentOffset.y
        if scrollView.isTracking { onUserScroll?(lastOffsetY - y) }
        lastOffsetY = y
        updateJump()
        let away = scrolledDistanceFromBottom > 80
        // A disclosure's glide is not the reader's scroll: following is settled when it ends.
        if foldHolding, !scrollView.isTracking { return }
        if scrollView.isTracking || scrollView.isDecelerating {
            surface.following = !away
        } else if !away, surface.find?.currentMatch == nil {
            // A Find jump that lands near the bottom keeps the reader on its match: only the
            // person's own scroll resumes following while a match is shown.
            surface.following = true
        }
    }

    /// Shows the jump button only for a real scroll away from the newest
    /// turn: never for an empty chat, the rubber band, or a drag that is
    /// pulling the keyboard down (verify/jump-button.md).
    private func updateJump() {
        let shown: Bool
        if isEmpty {
            jumpVisibility = JumpToBottomVisibility()
            shown = false
        } else {
            shown = jumpVisibility.update(offsetY: scrollView.contentOffset.y, minOffsetY: -scrollView.contentInset.top,
                                          maxOffsetY: bottomOffset.y, keyboardDragging: keyboardDragging)
        }
        guard surface.showJump != shown else { return }
        withAnimation(.cmuxMobileSnap) { surface.showJump = shown }
        jumpHost?.view.isUserInteractionEnabled = shown
    }

    func scrollTranscript(toTop: Bool, animated: Bool) {
        endFoldHold(force: true)
        surface.following = !toTop
        view.layoutIfNeeded()
        scroll(to: toTop ? CGPoint(x: 0, y: -scrollView.contentInset.top) : bottomOffset, animated: animated)
    }

    /// Room the find bar takes under the header (its 44 pt row and its margins).
    static let findBarClearance: CGFloat = 64

    func scrollTranscript(toContentY y: CGFloat, animated: Bool) {
        endFoldHold(force: true)
        surface.following = false
        view.layoutIfNeeded()
        let headerBottom = topInset ?? view.safeAreaInsets.top
        let wanted = y - headerBottom - Self.findBarClearance
        let target = CGPoint(x: 0, y: min(max(-scrollView.contentInset.top, wanted), max(-scrollView.contentInset.top, bottomOffset.y)))
        scroll(to: target, animated: animated)
    }

    func revealFindBlock(_ findBlock: String, position: Double, animated: Bool) {
        let id = ChatTranscriptList.rowID(findBlock: findBlock)
        list.layOutNow(id)
        view.layoutIfNeeded()
        guard let top = list.layout.top(of: id) else { return }
        // Within a row taller than the screen (a long paragraph or code card), the match's
        // place in the row's text, as a share of the row's height.
        let height = list.layout.height(of: id) ?? 0
        scrollTranscript(toContentY: top + max(0, height * CGFloat(position) - 24), animated: animated)
    }

    /// Reduce Motion: a jump lands at once, with the transcript shown
    /// throughout. Tests set it.
    var reducesMotion: () -> Bool = { UIAccessibility.isReduceMotionEnabled }

    /// The transcript's list and whether a tapped disclosure's line is held (tests).
    var transcriptList: ChatTranscriptList { list }
    var isHoldingFold: Bool { foldHolding }

    private func scroll(to target: CGPoint, animated: Bool) {
        if animated, !reducesMotion() {
            // A long jump animated the offset across pages SwiftUI had not drawn yet (a
            // blank band and stale fragments for ~300 ms). Cut to one screen short of the
            // target, then animate only that last screen.
            let screen = scrollView.bounds.height
            let distance = target.y - scrollView.contentOffset.y
            if abs(distance) > screen * 1.5 {
                // The cut lands with no implicit animations, and the transcript stays hidden
                // for the frame SwiftUI needs to draw the new rows (a tile was drawn over the
                // composer for one frame); it fades back in with the final animation.
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                scrollView.contentOffset = CGPoint(x: 0, y: target.y - (distance > 0 ? screen : -screen))
                scrollView.layoutIfNeeded()
                CATransaction.commit()
            }
            UIView.animate(springDuration: 0.4, bounce: 0) { self.scrollView.contentOffset = target }
        } else {
            scrollView.contentOffset = target
        }
    }

    // MARK: Trace

    #if DEBUG
    /// Per-frame geometry for `verify/keyboard.md` (window coordinates,
    /// presentation values, so what is on screen this frame).
    func traceLine() -> String {
        func pres(_ v: UIView?) -> CGRect? {
            guard let v, let window = v.window else { return nil }
            return ChatKeyboardTrace.onScreen(v, in: window)
        }
        let window = view.window
        let keyboardTop = ChatKeyboardTrace.keyboardTop(in: window)
        let scrollPres = scrollView.layer.presentation() ?? scrollView.layer
        let scrollBoundsY = scrollPres.bounds.origin.y
        let scrollFrame = pres(scrollView) ?? .zero
        let contentBottom = scrollFrame.minY + contentHeight - scrollBoundsY
        // The guide as laid out this frame: its bottom is the host's
        // presentation bottom (owned), its height the model height.
        let guideDock = window.map { view.convert(dockGuide.layoutFrame, to: $0) }
        let dock: CGRect? = placement == .owned ? pres(dockContainer).map {
            CGRect(x: $0.minX, y: $0.maxY - (guideDock?.height ?? 0), width: $0.width, height: guideDock?.height ?? 0)
        } : nil
        let empty = surfaceIsEmpty ? pres(emptyHost.view) : nil
        let navBar = ChatKeyboardTrace.navigationBar(in: window).flatMap { pres($0) }
        // The composer card as drawn (its glass view), in either placement.
        let card = window.flatMap { ChatKeyboardTrace.composerCard(in: $0) }.flatMap { pres($0) }
        let jumpFrame = pres(jumpHost?.view)
        func f(_ v: CGFloat?) -> String { v.map { String(format: "%.2f", $0) } ?? "-" }
        return [
            "kb=\(f(keyboardTop))",
            "guide=\(f(window.map { view.convert(view.keyboardLayoutGuide.layoutFrame, to: $0).minY }))",
            "dockTop=\(f(dock?.minY ?? guideDock?.minY))", "dockBottom=\(f(dock?.maxY ?? guideDock?.maxY))",
            "cardTop=\(f(card?.minY))", "cardBottom=\(f(card?.maxY))",
            "contentBottom=\(f(contentHeight > 0 ? contentBottom : nil))",
            "emptyMid=\(f(empty?.midY))",
            "nav=\(f(navBar?.minY)),\(f(navBar?.maxY))",
            "tracking=\(scrollView.isTracking ? 1 : 0)",
            "offset=\(f(scrollBoundsY))",
            "stackH=\(f(stackHeight))", "drawnH=\(f(surface.drawnStackHeight))", "reportedH=\(f(surface.stackHeight))",
            // verify/jump-button.md: the button's state, its host as drawn,
            // and the scroll range it is judged against.
            "jump=\(surface.showJump ? 1 : 0)",
            "jumpFrame=\(f(jumpFrame?.minX)),\(f(jumpFrame?.minY)),\(f(jumpFrame?.width)),\(f(jumpFrame?.height))",
            "minOffset=\(f(-scrollView.contentInset.top))", "maxOffset=\(f(bottomOffset.y))",
            "kbdrag=\(keyboardDragging ? 1 : 0)",
        ].joined(separator: " ")
    }
    #endif
}

/// Runs a block at the next display frame (after the current main-queue
/// turn and whatever it blocks), where SwiftUI starts the animations it was
/// asked for in that turn.
@MainActor
private final class NextFrame: NSObject {
    private var block: (() -> Void)?
    private var link: CADisplayLink?

    static func run(_ block: @escaping () -> Void) {
        let next = NextFrame()
        next.block = block
        let link = CADisplayLink(target: next, selector: #selector(tick))
        next.link = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func tick() {
        link?.invalidate()
        link = nil
        block?()
        block = nil
    }
}

/// Takes touches only in its bottom `interactiveHeight` (the stack); the
/// empty space above lets them through to the transcript. (SwiftUI handles
/// its gestures in the hosting view itself, so the hit view cannot tell.)
final class PassthroughView: UIView {
    var interactiveHeight: CGFloat = 0

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        point.y >= bounds.height - interactiveHeight && super.point(inside: point, with: event)
    }
}

/// Breaks the display link's retain of the controller.
@MainActor
private final class DragLinkTarget: NSObject {
    weak var owner: ChatTranscriptController?
    init(_ owner: ChatTranscriptController) { self.owner = owner }
    @objc func tick() { owner?.draggedKeyboardFrame() }
}

/// Lets the composer's swipe-down recognizer run beside the text view's own.
private final class DockPanDelegate: NSObject, UIGestureRecognizerDelegate {
    @MainActor static let shared = DockPanDelegate()
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

/// SwiftUI wrapper for `ChatTranscriptController`.
struct ChatTranscriptRepresentable: UIViewControllerRepresentable {
    let placement: ChatDockPlacement
    let surface: AgentChatSurface
    var topInset: CGFloat?
    var onUserScroll: ((CGFloat) -> Void)?
    var isEmpty: Bool
    /// The store shown (see `ChatTranscriptController.update`).
    let store: AgentChatStore
    /// Sets the rows' environment (open a diff or a file, attachments, links).
    let configureRows: (ChatRowContext) -> Void
    let empty: AnyView
    let dock: AnyView?
    let jump: AnyView?

    func makeUIViewController(context: Context) -> ChatTranscriptController {
        let controller = ChatTranscriptController(placement: placement, surface: surface, store: store, empty: empty, dock: dock, jump: jump)
        controller.topInset = topInset
        controller.onUserScroll = onUserScroll
        controller.isEmpty = isEmpty
        controller.update(store: store, empty: empty, dock: dock, jump: jump)
        configureRows(controller.rowContext)
        return controller
    }

    func updateUIViewController(_ controller: ChatTranscriptController, context: Context) {
        controller.topInset = topInset
        controller.onUserScroll = onUserScroll
        // Read here so SwiftUI calls update when they change.
        _ = (surface.stackHeight, surface.stackMaxY, surface.composerFocused, surface.showJump)
        controller.isEmpty = isEmpty
        controller.update(store: store, empty: empty, dock: dock, jump: jump)
        configureRows(controller.rowContext)
    }
}

#if DEBUG
/// `-cmux-mobile-kbd-trace`: one line per display frame to
/// `Documents/kbd-trace.txt` (verify/keyboard.md).
@MainActor
final class ChatKeyboardTrace {
    static var isEnabled: Bool { CommandLine.arguments.contains("-cmux-mobile-kbd-trace") }
    private weak var owner: ChatTranscriptController?
    private var link: CADisplayLink?
    private let handle: FileHandle?
    private let start = CACurrentMediaTime()

    init(owner: ChatTranscriptController) {
        self.owner = owner
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("kbd-trace.txt")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let owner else {
            link.invalidate()
            return
        }
        guard owner.view.window != nil else { return }
        let line = String(format: "t=%.4f ", link.targetTimestamp - start) + "mode=\(owner.placement == .owned ? "pushed" : "tab") " + owner.traceLine() + "\n"
        handle?.write(Data(line.utf8))
    }

    static func keyboardTop(in window: UIWindow?) -> CGFloat? {
        MobileKeyboardProbe().drawnTop(in: window) ?? window?.bounds.maxY
    }

    static func onScreen(_ view: UIView, in window: UIView) -> CGRect {
        MobileKeyboardProbe().onScreen(view, in: window)
    }

    /// The composer's glass card: the widest glass view in the window.
    static func composerCard(in window: UIWindow) -> UIView? {
        var best: UIView?
        func walk(_ v: UIView) {
            if v.bounds.width > 300, v.bounds.height < 400, NSStringFromClass(type(of: v)).contains("Glass") {
                if best == nil || v.bounds.width > best!.bounds.width { best = v }
            }
            for sub in v.subviews { walk(sub) }
        }
        walk(window)
        return best
    }

    static func navigationBar(in window: UIWindow?) -> UIView? {
        guard let window else { return nil }
        return find(in: window) { $0 is UINavigationBar && !$0.isHidden && $0.window != nil && $0.frame.height > 0 }
    }

    private static func find(in view: UIView, where match: (UIView) -> Bool) -> UIView? {
        MobileKeyboardProbe().find(in: view, where: match)
    }
}
#endif
#endif

#if os(iOS)
/// Solid over the status bar, then fades to clear at the content inset so the
/// first row at rest is unobscured. Matches the embedded terminal's fallback.
@MainActor
private final class TopFadeView: UIView {
    private static let tail: CGFloat = 18

    override class var layerClass: AnyClass { CAGradientLayer.self }

    private var gradient: CAGradientLayer { layer as! CAGradientLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: TopFadeView, _: UITraitCollection) in
            view.updateColors()
        }
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let solid = max(0, bounds.height - Self.tail) / max(bounds.height, 1)
        gradient.locations = [0, NSNumber(value: Double(solid)), 1]
    }

    private func updateColors() {
        let color = UIColor(Color.cmuxMobileBackground).resolvedColor(with: traitCollection)
        gradient.colors = [color.cgColor, color.cgColor, color.withAlphaComponent(0).cgColor]
    }
}
#endif
