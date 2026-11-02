#if os(iOS)
import CmuxConversationCore
import CmuxMobileArtifacts
import CmuxConversationUI
import CmuxMobileModel
import CmuxMobileSupport
import SwiftUI
import UIKit

/// A navigation value that opens the Chief conversation.
public struct ChiefRoute: Hashable, Sendable {
    /// Which Chief, fixed when the route is pushed: an open conversation
    /// never switches Chief when the default one changes under it.
    public enum Place: Hashable, Sendable {
        case cloud
        case mac
    }

    /// Home's compose button: the keyboard rises once the push settles.
    public var focusesComposer: Bool
    public var place: Place

    public init(focusesComposer: Bool = false, place: Place = .mac) {
        self.focusesComposer = focusesComposer
        self.place = place
    }
}

/// The Chief conversation: CmuxConversation's Messages-style
/// `ConversationViewController` over the shared `ChiefSession` store, pushed
/// on Home's navigation stack. It draws its own glass header (back, avatar,
/// name) and owns the bottom edge, so the SwiftUI navigation bar and the tab
/// bar are hidden while it is up; the header's back button and the system
/// left-edge swipe both pop it.
///
/// The header's avatar and name push Chief's info (``ChiefSettingsView``)
/// on the same stack, as Messages pushes contact details from the
/// conversation header: a back chevron and the system swipe back return to
/// the conversation. The trailing button is Invite to cmux
/// (``ChiefInvite``): the share sheet with a note and the public cmux link.
public struct ChiefConversationScreen: View {
    let session: ChiefSession
    let compose: ChiefComposer?
    let focusesComposer: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var showsInfo = false
    @State private var link = ChiefScreenLink()

    public init(session: ChiefSession = .shared, compose: ChiefComposer? = nil, focusesComposer: Bool = false) {
        #if DEBUG
        if DeveloperOptions.mockContentEnabled, CommandLine.arguments.contains("-cmux-mobile-chief-outbox-demo") {
            self.session = Self.outboxDemo
        } else {
            self.session = session
        }
        #else
        self.session = session
        #endif
        self.compose = compose
        self.focusesComposer = focusesComposer
    }

    #if DEBUG
    /// An isolated, memory-only outbox for capture; never changes a real queue.
    private static let outboxDemo: ChiefSession = {
        let session = ChiefSession(backend: ChiefOfflineBackend(), outbox: ChiefOutbox(file: nil))
        session.status = "Offline"
        session.send(ConversationComposeMessage(text: "Check the latest build."), asksForAlerts: false)
        session.send(ConversationComposeMessage(text: "Let me know when the tests finish."), asksForAlerts: false)
        return session
    }()
    #endif

    public var body: some View {
        ChiefConversationController(session: session, compose: compose, focusesComposer: focusesComposer, link: link,
                                    back: { dismiss() }, openInfo: { showsInfo = true })
            // The conversation draws one store; a new backend (Try Again, a new link) makes a
            // new store, so the open screen is rebuilt on it instead of waiting on the old one.
            .id(ObjectIdentifier(session.store))
            .ignoresSafeArea()
            .toolbar(.hidden, for: .navigationBar)
            .navigationBarBackButtonHidden()
            .navigationDestination(isPresented: $showsInfo) {
                // Message: back to the conversation with the keyboard up.
                ChiefSettingsView(session: session) { [link] in
                    link.container?.focusesComposerOnAppear = true
                    showsInfo = false
                }
            }
    }
}

/// The conversation screen's UIKit container, for the info page's Message
/// button (it focuses the composer once the pop settles).
@MainActor final class ChiefScreenLink {
    weak var container: ChiefConversationContainer?
    /// The route's composer focus was handed to a container already.
    var focusedComposer = false
}

/// Chief's service line in the transcript's start header, replacing
/// Messages' "iMessage / Encrypted".
extension ConversationPresentationOptions {
    public static var chief: ConversationPresentationOptions {
        ConversationPresentationOptions(
            placeholder: String(localized: "Message Chief"),
            serviceTitle: "Chief",
            serviceSubtitle: String(localized: "mobile.chief.serviceSubtitle", defaultValue: "Runs your agents", bundle: .module),
            // The header's trailing button is Invite to cmux (the share sheet).
            trailingSymbol: ChiefInvite.symbol,
            header: ConversationHeaderPresentation(
                scrollEdge: .system,
                actionAccessibilityLabel: ChiefInvite.actionTitle,
                avatarAccessibilityLabel: String(localized: "Chief"),
                avatarAccessibilityHint: String(localized: "Opens Chief's settings")
            )
        )
    }
}

struct ChiefConversationController: UIViewControllerRepresentable {
    let session: ChiefSession
    let compose: ChiefComposer?
    let focusesComposer: Bool
    let link: ChiefScreenLink
    let back: () -> Void
    let openInfo: () -> Void

    func makeUIViewController(context: Context) -> ChiefConversationContainer {
        let conversation = ConversationViewController(store: session.store, options: .chief,
                                                      keyboard: context.environment.mobileKeyboardFrameTracker)
        let container = ChiefConversationContainer(conversation: conversation, session: session)
        // Home's compose focuses the composer once: a container rebuilt on a
        // new store (Try Again) opens without the keyboard.
        container.focusesComposerOnAppear = focusesComposer && !link.focusedComposer
        link.focusedComposer = true
        container.openInfo = openInfo
        link.container = container
        configure(conversation)
        #if DEBUG
        ChiefDemoHook.shared.controller = conversation
        #endif
        return container
    }

    func updateUIViewController(_ container: ChiefConversationContainer, context: Context) {
        container.openInfo = openInfo
        link.container = container
        configure(container.conversation)
    }

    private func configure(_ conversation: ConversationViewController) {
        conversation.onBack = back
        // A file link in a Chief message opens the file preview (read from
        // Chief's Mac), a cmux link what it names; web links open in Safari as before.
        conversation.onOpenLink = { [weak session, weak conversation] url in
            if CmuxLinkOpener.shared.open(url) { return true }
            guard let link = FileLink(url: url), let session, let conversation else { return false }
            // Something is already up (Quick Look, a sheet): the tap does nothing.
            guard conversation.presentedViewController == nil else { return true }
            let source = session.fileSource ?? UnavailableArtifactSource()
            FilePreviewRequest(reference: link.reference, source: source, line: link.line).present(from: conversation)
            return true
        }
        // Select mode's Forward opens New Message with the draft, as in the lab.
        // A conversation of the Mac's Home list has no composer: no Forward
        // button there (it did nothing when tapped).
        conversation.onForward = compose.map { compose in { draft in compose.present(forwarding: draft) } }
    }
}

/// Holds the conversation as a child, as the package's lab host does with
/// its navigation controller (bar hidden; the package draws the header,
/// backdrop and composer and owns safe areas and the keyboard), and keeps the
/// left-edge swipe back that SwiftUI turns off while the bar is hidden. The
/// transcript's pans wait for that swipe, so a drag from the edge pops
/// instead of replying to the bubble under it or opening the send times.
public final class ChiefConversationContainer: UIViewController, UIGestureRecognizerDelegate {
    let conversation: ConversationViewController
    let session: ChiefSession
    private var popRecognizers: [UIGestureRecognizer] = []
    private var previousPopDelegates: [ObjectIdentifier: WeakDelegate] = [:]
    private struct WeakDelegate { weak var value: (any UIGestureRecognizerDelegate)? }

    init(conversation: ConversationViewController, session: ChiefSession) {
        self.conversation = conversation
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func viewDidLoad() {
        super.viewDidLoad()
        addChild(conversation)
        conversation.view.frame = view.bounds
        conversation.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(conversation.view)
        conversation.didMove(toParent: self)
        takeOverHeader()
        installQuestionBar()
        installLiveBubble()
        // The header redraws only when the title changes; a new avatar from
        // the Mac (chief-profile-changed) redraws it in place.
        headerAvatar = chiefInitials
        conversation.store.addObserver { [weak self] _ in
            guard let self, self.isViewLoaded else { return }
            self.updateAvailability()
            guard self.chiefInitials != self.headerAvatar else { return }
            self.headerAvatar = self.chiefInitials
            if self.view.window != nil { self.conversation.setBackUnreadCount(self.backUnreadCount) }
        }
        installSendGate()
        observeAvailability()
    }

    // MARK: Chief unavailable (full verify D2, D3)

    /// The package's send action, kept while the gate holds the button.
    private var packageSendActions: [UIAction] = []
    private weak var sendButton: UIButton?

    /// Before Chief ever connected, the package's send clears the composer
    /// and then drops the message (its store has no sender yet). The send
    /// button goes through this gate: once Chief takes sends it runs the
    /// package's own action; until then the text stays in the composer and
    /// the screen says why, with Try Again and Send When Chief Connects.
    private func installSendGate() {
        guard let button = conversation.view.firstSubview(where: { $0.accessibilityIdentifier == "conversation.composer.send" }) as? UIButton
        else { return }
        var actions: [UIAction] = []
        button.enumerateEventHandlers { action, _, event, _ in
            if event == .touchUpInside, let action { actions.append(action) }
        }
        guard !actions.isEmpty else { return }
        sendButton = button
        packageSendActions = actions
        for action in actions { button.removeAction(action, for: .touchUpInside) }
        button.addAction(UIAction { [weak self] _ in self?.sendTapped() }, for: .touchUpInside)
        updateAvailability()
    }

    private func sendTapped() {
        guard let button = sendButton else { return }
        if session.acceptsSendsNow {
            for action in packageSendActions { button.sendAction(action) }
            return
        }
        holdUnsentMessage()
    }

    private var composerTextView: UITextView? {
        conversation.view.firstSubview { $0.accessibilityIdentifier == "conversation.composer.text" } as? UITextView
    }

    /// The message stays in the composer; the alert says why and offers to
    /// try Chief again or to send it once Chief connects (the outbox).
    private func holdUnsentMessage() {
        guard presentedViewController == nil else { return }
        let text = composerTextView?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let alert = UIAlertController(
            title: String(localized: "mobile.chief.notSent", defaultValue: "Not sent", bundle: .module),
            message: String(localized: "mobile.chief.draftKept", defaultValue: "Your draft is saved here.", bundle: .module),
            preferredStyle: .alert)
        if session.canRetryConnecting {
            alert.addAction(UIAlertAction(title: String(localized: "Try Again"), style: .default) { [weak self] _ in
                self?.session.retryConnecting()
            })
        }
        if !text.isEmpty {
            alert.addAction(UIAlertAction(title: String(localized: "Send When Chief Connects"), style: .default) { [weak self] _ in
                self?.moveComposerToOutbox(text)
            })
        }
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .cancel))
        present(alert, animated: true)
    }

    private func moveComposerToOutbox(_ text: String) {
        session.send(ConversationComposeMessage(text: text))
        guard let field = composerTextView else { return }
        field.text = ""
        // The composer follows its field through the delegate (send button, height).
        field.delegate?.textViewDidChange?(field)
    }

    /// Follows the session for the gate and the spinner.
    private func observeAvailability() {
        withObservationTracking {
            _ = session.barItem
            _ = session.isConnected
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.updateAvailability()
                self?.observeAvailability()
            }
        }
    }

    /// The package's first-load spinner never ends while Chief is unavailable:
    /// hidden while the bar says why. The effect long-press on Send would
    /// also clear and drop: off until Chief takes sends.
    private func updateAvailability() {
        let unavailable: Bool
        if case .unavailable? = session.barItem { unavailable = true } else { unavailable = false }
        let sends = session.acceptsSendsNow
        // Found once (the store changes on every keystroke and stream chunk).
        if gatedViews.spinner == nil { gatedViews.spinner = packageView("conversation.initialLoading") }
        if gatedViews.record == nil { gatedViews.record = packageView("conversation.composer.record") as? UIControl }
        if gatedViews.plus == nil { gatedViews.plus = packageView("conversation.composer.plus") as? UIControl }
        gatedViews.spinner?.alpha = unavailable ? 0 : 1
        // Voice messages, photos, polls and Send Later clear and drop the same way before
        // Chief connects: off until it takes sends (the text field and its gated Send stay).
        gatedViews.record?.isEnabled = sends
        gatedViews.plus?.isEnabled = sends
        for recognizer in sendButton?.gestureRecognizers ?? [] where recognizer is UILongPressGestureRecognizer {
            recognizer.isEnabled = sends
        }
    }

    /// With the Mac offline (the Mac Chief on its cloud copy), the bar's Ask
    /// Cloud Chief hands the composer's text, or my newest message, to the
    /// Cloud Chief with the recent messages as context (``ChiefSources/askCloudChief(_:)``).
    private func askCloudChief() {
        let typed = composerTextView?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let mine = session.store.messages.last { $0.senderID == session.identity.meID }?.text ?? ""
        let request = typed.isEmpty ? mine : typed
        guard !request.isEmpty else { return }
        Task { await ChiefSources.shared.askCloudChief(request) }
        if !typed.isEmpty, let field = composerTextView {
            field.text = ""
            field.delegate?.textViewDidChange?(field)
        }
        let alert = UIAlertController(
            title: String(localized: "Sent to Cloud Chief"),
            message: String(localized: "mobile.chief.continueInCloud", defaultValue: "Continue in the Cloud Chief chat.", bundle: .module),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .cancel))
        present(alert, animated: true)
    }

    private struct GatedViews {
        weak var spinner: UIView?
        weak var record: UIControl?
        weak var plus: UIControl?
    }

    private var gatedViews = GatedViews()

    private func packageView(_ identifier: String) -> UIView? {
        conversation.view.firstSubview { $0.accessibilityIdentifier == identifier }
    }

    // MARK: Chief's questions

    /// The bar under the header while Chief asks (``ChiefQuestionBar``).
    private lazy var questionBar: UIHostingController<ChiefQuestionBar> = {
        var bar = ChiefQuestionBar(session: session) { [weak self] question in
            self?.presentQuestion(question.id)
        }
        bar.resized = { [weak self] in self?.view.setNeedsLayout() }
        bar.askCloudChief = { [weak self] in self?.askCloudChief() }
        bar.fading = { [weak self] out, duration in
            guard let self else { return }
            UIView.animate(withDuration: duration) { self.topBand.alpha = out ? 0 : 1 }
        }
        let host = UIHostingController(rootView: bar)
        host.view.backgroundColor = .clear
        host.sizingOptions = .intrinsicContentSize
        return host
    }()

    /// One solid band from the top of the screen to just below the bar
    /// (R3-1): no scrolled-out bubble shows behind the clock or around the
    /// bar, so the status bar and the bar read as one top bar. Goes once the
    /// package can host the bar under its header (UPSTREAM-REQUESTS.md U8).
    private let topBand: UIView = {
        let band = UIView()
        band.backgroundColor = .systemBackground
        band.isUserInteractionEnabled = false
        band.alpha = 0
        return band
    }()

    private func installQuestionBar() {
        view.addSubview(topBand)
        addChild(questionBar)
        view.addSubview(questionBar.view)
        questionBar.didMove(toParent: self)
    }

    /// The bar takes its own room (R2-1), as Messages' pinned rows do:
    /// the conversation is inset from the top by the bar's height + 8 pt, so
    /// its header and transcript start below the bar and nothing in the
    /// conversation is ever under it. The bar sits in that room, under the
    /// status bar. (CmuxConversation pins its header to the safe area and the
    /// transcript to the header, so a safe-area inset moves both; a hook to
    /// put the bar under the header is upstream request U8.)
    private func layoutQuestionBar() {
        guard questionBar.parent === self else { return }
        let size = questionBar.sizeThatFits(in: CGSize(width: view.bounds.width, height: .greatestFiniteMagnitude))
        let height = size.height < 1 ? 0 : size.height
        let top = view.safeAreaInsets.top + 4
        questionBar.view.frame = CGRect(x: 0, y: top, width: view.bounds.width, height: height)
        if height > 0 { topBand.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: top + height + 4) }
        let inset: CGFloat = height > 0 ? height + 8 : 0
        guard conversation.additionalSafeAreaInsets.top != inset else { return }
        let apply = { [conversation] in
            conversation.additionalSafeAreaInsets.top = inset
            conversation.view.layoutIfNeeded()
        }
        if view.window != nil, !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0, options: [.allowUserInteraction], animations: apply)
        } else {
            apply()
        }
    }

    // MARK: Chief's streaming reply

    /// The streaming reply bubble and status line (``ChiefLiveBubble``),
    /// over the end of the transcript. Only the status line and its details
    /// take touches (``ChiefLiveHitArea``); everywhere else the transcript
    /// under it scrolls and takes long-presses as usual.
    private let liveHitArea = ChiefLiveHitArea()
    private lazy var liveBubble: UIHostingController<ChiefLiveBubble> = {
        let host = UIHostingController(rootView: ChiefLiveBubble(session: session, hitArea: liveHitArea))
        host.view.backgroundColor = .clear
        host.sizingOptions = .intrinsicContentSize
        host.view.translatesAutoresizingMaskIntoConstraints = false
        return host
    }()
    private lazy var liveBubbleContainer: ChiefLivePassthroughView = {
        let container = ChiefLivePassthroughView(hitArea: liveHitArea)
        container.translatesAutoresizingMaskIntoConstraints = false
        return container
    }()
    /// The bubble's bottom: on the composer once it is found, else the safe area.
    private var liveBubbleBottom: NSLayoutConstraint?
    private var liveBubbleOnComposer = false

    private func installLiveBubble() {
        view.addSubview(liveBubbleContainer)
        addChild(liveBubble)
        liveBubbleContainer.addSubview(liveBubble.view)
        liveBubble.didMove(toParent: self)
        NSLayoutConstraint.activate([
            liveBubbleContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            liveBubbleContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            liveBubble.view.leadingAnchor.constraint(equalTo: liveBubbleContainer.leadingAnchor),
            liveBubble.view.trailingAnchor.constraint(equalTo: liveBubbleContainer.trailingAnchor),
            liveBubble.view.topAnchor.constraint(equalTo: liveBubbleContainer.topAnchor),
            liveBubble.view.bottomAnchor.constraint(equalTo: liveBubbleContainer.bottomAnchor),
        ])
        anchorLiveBubble()
    }

    /// Pins the bubble just above the package's composer (found by its
    /// accessibility marker), so it rides the keyboard with it. A package
    /// that renames the marker leaves it above the bottom safe area.
    private func anchorLiveBubble() {
        guard !liveBubbleOnComposer, liveBubble.parent === self else { return }
        let field = conversation.view.firstSubview { $0.accessibilityIdentifier == "conversation.composer.text" }
        let bottom: NSLayoutConstraint
        if let field {
            bottom = liveBubbleContainer.bottomAnchor.constraint(equalTo: field.topAnchor, constant: -18)
            liveBubbleOnComposer = true
        } else if liveBubbleBottom == nil {
            bottom = liveBubbleContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -72)
        } else {
            return
        }
        liveBubbleBottom?.isActive = false
        bottom.isActive = true
        liveBubbleBottom = bottom
    }

    public func presentQuestion(_ id: String) {
        guard presentedViewController == nil, conversation.presentedViewController == nil else { return }
        view.endEditing(true)
        let host = UIHostingController(rootView: ChiefQuestionSheet(session: session, questionID: id))
        host.modalPresentationStyle = .pageSheet
        host.sheetPresentationController?.detents = [.medium(), .large()]
        host.sheetPresentationController?.prefersGrabberVisible = true
        // At accessibility sizes the card does not fit half a screen.
        if traitCollection.preferredContentSizeCategory.isAccessibilityCategory {
            host.sheetPresentationController?.selectedDetentIdentifier = .large
        }
        present(host, animated: true)
    }

    private var headerAvatar: String?
    private var chiefInitials: String? {
        conversation.store.info?.participants.first { $0.id == session.identity.chiefID }?.initials
    }

    // MARK: Chief settings in place of contact details

    /// Public package actions preserve the close behavior in reply/edit/select
    /// modes and work for touch, VoiceOver and keyboard activation alike.
    private(set) var headerTakenOver = false

    private func takeOverHeader() {
        conversation.onHeaderInfo = { [weak self] in self?.presentSettings() }
        conversation.onHeaderAction = { [weak self] anchor in self?.presentInvite(anchor: anchor) }
        headerTakenOver = true
    }

    /// Messages written before Chief connected are not in the transcript
    /// yet; say so, with why, instead of showing nothing.
    private func showOutboxIfWaiting() {
        guard !session.outbox.isEmpty, !session.isConnected, presentedViewController == nil else { return }
        let count = session.outbox.count
        let reason = session.unavailableReason ?? String(localized: "Chief isn't connected yet.")
        let alert = UIAlertController(
            title: count == 1 ? String(localized: "Message Not Sent Yet") : String(localized: "\(count) Messages Not Sent Yet"),
            message: String(localized: "\(reason) It will send when Chief connects."),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Keep"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Delete"), style: .destructive) { [weak self] _ in
            self?.session.discardOutbox()
        })
        present(alert, animated: true)
    }
    /// Pushes Chief's info on the navigation stack (``ChiefConversationScreen``).
    var openInfo: (() -> Void)?

    public func presentSettings() {
        guard presentedViewController == nil, conversation.presentedViewController == nil else { return }
        view.endEditing(true)
        openInfo?()
    }

    /// Invite to cmux: the share sheet over the conversation, anchored to the
    /// trailing button (a popover on iPad).
    public func presentInvite(anchor: UIView? = nil) {
        guard presentedViewController == nil, conversation.presentedViewController == nil else { return }
        view.endEditing(true)
        let sheet = ChiefInvite.shareSheet()
        if let popover = sheet.popoverPresentationController {
            if let anchor {
                popover.sourceView = anchor
                popover.sourceRect = anchor.bounds
            } else {
                popover.sourceView = view
                popover.sourceRect = CGRect(x: view.bounds.maxX - 44, y: view.safeAreaInsets.top, width: 1, height: 1)
            }
        }
        present(sheet, animated: true)
    }

    /// The back button's count of other unread conversations, the way the
    /// package's lab host feeds it (`ConversationUnreadBadge`). Setting it
    /// also configures the header from the store; the shared Chief store is
    /// usually connected before this screen exists, so no later store change
    /// would configure it once the header is in a window.
    var backUnreadCount = 0 {
        didSet { if isViewLoaded, view.window != nil { conversation.setBackUnreadCount(backUnreadCount) } }
    }

    public override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        conversation.setBackUnreadCount(backUnreadCount)
    }

    /// SwiftUI turns the edge pop off again whenever it updates the hidden
    /// bar (appear and layout), as the workspace screen found
    /// (verify/navigation.md), so it is re-enabled on every layout.
    /// Covered by a pushed page (Chief's info): its view stays in the window
    /// through the push, and the back swipes belong to the page on top.
    private var isCovered = false

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isCovered = false
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if view.window != nil, !isCovered { enableEdgePop() }
        layoutQuestionBar()
        anchorLiveBubble()
    }

    /// The back swipe from the left edge, as in Messages. On iOS 26 and later
    /// UIKit drives that swipe with the content pop recognizer, which also
    /// takes a rightward drag anywhere; Chief limits it to the edge strip,
    /// because a rightward drag on a bubble replies to it and a leftward
    /// drag on the transcript reveals send times.
    private func enableEdgePop() {
        guard let navigation = navigationController else { return }
        var recognizers: [UIGestureRecognizer] = []
        if let pop = navigation.interactivePopGestureRecognizer { recognizers.append(pop) }
        if #available(iOS 26.0, *), let content = navigation.interactiveContentPopGestureRecognizer { recognizers.append(content) }
        for recognizer in recognizers {
            if recognizer.delegate !== self {
                // A Chief screen rebuilt on a new store (Try Again) takes over from the old one:
                // keep the navigation's own delegate, never the outgoing Chief screen.
                if let outgoing = recognizer.delegate as? ChiefConversationContainer {
                    previousPopDelegates[ObjectIdentifier(recognizer)] = outgoing.previousPopDelegates[ObjectIdentifier(recognizer)]
                } else {
                    previousPopDelegates[ObjectIdentifier(recognizer)] = WeakDelegate(value: recognizer.delegate)
                }
            }
            recognizer.isEnabled = true
            recognizer.delegate = self
        }
        guard popRecognizers.map(ObjectIdentifier.init) != recognizers.map(ObjectIdentifier.init) else { return }
        popRecognizers = recognizers
        // Every pan of the transcript waits for the back swipe to fail: the
        // reply swipe, the composer swipe, and the transcript's scroll pan,
        // which also tracks sideways drags (the send-time drawer) and would
        // otherwise take an edge swipe before the pop could begin. The pops
        // fail as soon as a drag starts outside the edge strip.
        for recognizer in conversation.view.allGestureRecognizersInSubtree()
        where recognizer is UIPanGestureRecognizer && !recognizers.contains(recognizer) {
            for pop in recognizers { recognizer.require(toFail: pop) }
        }
    }

    /// The strip along the left edge where a back swipe may start.
    static let backSwipeEdgeWidth: CGFloat = 16
    /// How far the finger has moved when the content pop asks to begin.
    static let contentPopSlop: CGFloat = 30

    /// Home's compose pushed this screen: focus the composer once the push
    /// has settled, in the same turn as `viewDidAppear` (no delay).
    var focusesComposerOnAppear = false

    /// The package's composer field, found by its accessibility marker
    /// (CmuxConversation has no public focus call). A later package that
    /// renames it opens without the keyboard, never wrongly.
    private func focusComposer() {
        let field = conversation.view.firstSubview { $0.accessibilityIdentifier == "conversation.composer.text" }
        field?.becomeFirstResponder()
    }

    /// The Chief screen on screen now: a rebuilt one may appear before the old one disappears.
    private static weak var shown: ChiefConversationContainer?

    /// The conversation the Chief screen on screen shows (``ChiefSession/conversationOnScreen``).
    static var shownConversation: String? {
        guard let shown, shown.session.isVisible else { return nil }
        return shown.session.conversationID
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        enableEdgePop()
        Self.shown = self
        session.isVisible = true
        // Text written on the screen this one replaced (Try Again rebuilt it on a new store).
        if let carried = session.takeCarriedComposerText(), let field = composerTextView, field.text.isEmpty {
            field.text = carried
            field.delegate?.textViewDidChange?(field)
        }
        session.markSeen()
        if focusesComposerOnAppear {
            focusesComposerOnAppear = false
            if presentedViewController == nil { focusComposer() }
        }
        #if DEBUG
        ChiefDemoHook.shared.container = self
        #endif
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // A sheet over Chief keeps it on screen; so does the screen that replaced this one.
        // Chief's info pushed over it does not: the transcript is off screen.
        // Another Chief's screen pushed over this one: this Chief is not seen
        // (it no longer marks its messages seen or holds back their alerts).
        if presentedViewController == nil, Self.shown === self || Self.shown == nil || Self.shown?.session !== session {
            session.isVisible = false
        }
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isCovered = true
        // Unsent text goes with the session to a rebuilt screen (it reads it on appear).
        session.carryComposerText(composerTextView?.text ?? "")
        // Hand the recognizers back to their own delegates for the next screen.
        for recognizer in popRecognizers where recognizer.delegate === self {
            recognizer.delegate = previousPopDelegates[ObjectIdentifier(recognizer)]?.value
        }
        popRecognizers = []
    }

    public func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard popRecognizers.contains(recognizer) else { return true }
        guard let navigation = navigationController, navigation.viewControllers.count > 1 else { return false }
        // UIKit already limits the edge pop to the screen edge.
        if recognizer === navigation.interactivePopGestureRecognizer { return true }
        // On iOS 26 and later the content pop drives the edge swipe too, and
        // it would take a rightward drag anywhere: only from the edge strip
        // here. UIKit asks once the finger has travelled its slop (measured:
        // a drag from x = 1 is asked at x = 31, with no translation yet).
        return recognizer.location(in: view).x <= Self.backSwipeEdgeWidth + Self.contentPopSlop
    }

    public func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        false
    }
}

private extension UIView {
    func allGestureRecognizersInSubtree() -> [UIGestureRecognizer] {
        (gestureRecognizers ?? []) + subviews.flatMap { $0.allGestureRecognizersInSubtree() }
    }

    func firstSubview(where match: (UIView) -> Bool) -> UIView? {
        for view in subviews {
            if match(view) { return view }
            if let found = view.firstSubview(where: match) { return found }
        }
        return nil
    }

    func subviewsOfType<T: UIView>(_ type: T.Type) -> [T] {
        subviews.flatMap { view -> [T] in
            if let match = view as? T { return [match] }
            return view.subviewsOfType(type)
        }
    }
}

#if DEBUG
/// DEBUG: lets the demo driver run CmuxConversation's lab verbs (`send`,
/// `doubletap`, `react`, `timestamps`, ...) on the open Chief conversation,
/// the same paths its gestures take, and scroll its transcript.
@MainActor
public final class ChiefDemoHook {
    public static let shared = ChiefDemoHook()
    weak var controller: ConversationViewController?
    weak var container: ChiefConversationContainer?
    /// The open New Message sheet, if any.
    weak var compose: ConversationComposeViewController?

    @discardableResult
    public func lab(_ line: String) -> String {
        controller?.labCommand(line) ?? "error no conversation"
    }

    /// CmuxConversation's photo lab verbs (`drawer`, `send`, `viewer`, `close`).
    @discardableResult
    public func photoLab(_ line: String) -> String {
        controller?.photoLabCommand(line) ?? "error no conversation"
    }

    /// New Message's lab verbs (`to`, `pick`, `body`, `send`, ...).
    @discardableResult
    public func composeLab(_ line: String) -> String {
        compose?.labCommand(line) ?? "error no compose"
    }

    /// Picks a photo as the composer's attachment, as the Photos drawer does.
    public func attachPhoto(_ image: UIImage) {
        guard let controller, let data = image.jpegData(compressionQuality: 0.85) else { return }
        controller.store.send(text: "", images: [(data: data, width: Int(image.size.width * image.scale), height: Int(image.size.height * image.scale), mimeType: "image/jpeg")])
    }

    /// Opens Chief's settings, as the header's avatar does.
    public func openSettings() {
        container?.presentSettings()
    }

    /// Opens the Invite to cmux share sheet, as the header's trailing button does.
    public func openInvite() {
        container?.presentInvite()
    }

    /// The header controls Chief took over (avatar, name, trailing).
    public var headerTakenOver: Bool { container?.headerTakenOver ?? false }

    /// Tapbacks the newest incoming message, as picking one in the bar does.
    public func react(_ name: String) {
        guard let reaction = ConversationReaction(rawValue: name), let store = controller?.store,
              let message = store.messages.last(where: { $0.senderID != store.meID && $0.seq != nil }) else { return }
        store.react(messageID: message.id, reaction: reaction)
    }

    /// Scrolls the transcript to the top (true) or the bottom (false).
    public func scroll(toTop: Bool) {
        guard let view = controller?.view,
              let transcript = view.subviews.compactMap({ $0 as? UICollectionView }).first else { return }
        let bottom = max(-transcript.adjustedContentInset.top,
                         transcript.contentSize.height + transcript.adjustedContentInset.bottom - transcript.bounds.height)
        let y = toTop ? -transcript.adjustedContentInset.top : bottom
        UIView.animate(withDuration: 0.9, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
            transcript.contentOffset.y = y
        }
    }
}
#endif
extension ChiefSession {
    /// The conversation a Chief screen shows now, nil when none is on screen:
    /// a notification about it needs no banner.
    public static var conversationOnScreen: String? { ChiefConversationContainer.shownConversation }
}
#endif
