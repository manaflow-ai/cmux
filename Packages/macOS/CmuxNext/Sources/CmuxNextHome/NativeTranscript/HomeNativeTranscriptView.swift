public import AppKit
public import CmuxHomeCore
import CmuxHomeRender
import CmuxNextDesign
import MessagesLabHome

/// The Home transcript (plans/cmux-next/home-mac.md): MessagesLabAppKitNative's
/// own code and motion (`MessagesLabHome`, vendored at MessagesLab 3a53206),
/// hosted in the pane over the shared HomeStore. The rows, springs, send
/// morph, Liquid Glass field and its render-server field animation, the
/// blurred header and native scrolling are MessagesLab's; this view adds the
/// cmux parts around it: the theme, the first-run panel, focus and
/// availability. Data reaches it only from HomeStore (the single writer);
/// sends and tapbacks leave as HomeIntents.
public final class HomeNativeTranscriptView: NSView {
    let transcript: MessagesLabHomeView
    let firstRun = HomeFirstRunView()
    let me: ParticipantID
    /// False while the owner is unreachable (H17: offline Send is off; the
    /// text stays a draft). The wiring sets it from `HomeStore.connection`.
    public var isSendEnabled = true {
        didSet { transcript.isSendEnabled = isSendEnabled }
    }
    /// A user-chosen sent-bubble colour; nil follows the theme.
    public var accentOverride: NSColor? { didSet { applyTheme() } }
    private var observers: [any NSObjectProtocol] = []

    public init(store: HomeStore, conversation: ConversationID, me: ParticipantID) {
        self.me = me
        transcript = MessagesLabHomeView(store: store, conversation: conversation, me: me, wake: HomeDemandWake())
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(transcript)
        addSubview(firstRun)
        firstRun.isHidden = true
        firstRun.onSuggestion = { [weak self] prompt in
            guard let self else { return }
            self.transcript.setDraft(prompt)
            self.window?.makeFirstResponder(self.transcript.primaryInput)
        }
        transcript.onSummaryChange = { [weak self] _ in self?.updateFirstRun() }
        transcript.onRowsChange = { [weak self] in self?.updateFirstRun() }
        applyTheme()
        updateFirstRun()
    }

    required init?(coder: NSCoder) { nil }

    isolated deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    /// Stops forwarding (the conversation closed).
    public func stop() { transcript.stop() }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    /// The primary input (spec/app-screens.md section 3): the message box's
    /// text view. Hosts focus this view, not the transcript.
    public var primaryInput: NSView { transcript.primaryInput }

    public override func becomeFirstResponder() -> Bool {
        window?.makeFirstResponder(primaryInput) ?? false
    }

    public override func layout() {
        super.layout()
        transcript.frame = bounds
        transcript.layoutSubtreeIfNeeded()
        let top = transcript.headerHeight
        firstRun.frame = CGRect(x: 0, y: top, width: bounds.width, height: max(0, transcript.fieldTop - top))
        updateFirstRun()
    }

    /// The first-run panel shows only in an empty Chief conversation.
    private func updateFirstRun() {
        firstRun.isHidden = !(transcript.isEmpty && transcript.conversationSummary?.kind(me: me) == .chief)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        guard let window else { return }
        let nc = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didChangeOcclusionStateNotification] {
            observers.append(nc.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowStateChanged() }
            })
        }
        windowStateChanged()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    private func windowStateChanged() {
        transcript.isVisibleToUser = window.map { $0.isKeyWindow && $0.occlusionState.contains(.visible) } ?? false
        applyTheme()
    }

    /// The theme's palettes (key and non-key window) for the MessagesLab
    /// Fixture colours, and the first-run panel's colours.
    private func applyTheme() {
        let accent = accentOverride
        let active = performWithTheme { HomeThemePalette.resolveInScope(active: true, accentOverride: accent) }
        let inactive = performWithTheme { HomeThemePalette.resolveInScope(active: false, accentOverride: accent) }
        transcript.applyTheme(active: active, inactive: inactive)
        performWithTheme {
            firstRun.applyColors(primary: Palette.textPrimary, secondary: Palette.textSecondary)
        }
    }
}
