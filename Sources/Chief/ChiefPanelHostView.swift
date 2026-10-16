import AppKit
import CmuxHomeCore

/// Owns the in-pane list and transcript, and carries focus through the initial mount.
@MainActor
final class ChiefPanelHostView: NSView {
    let homeView: ChiefHomeView
    var transcript: ChiefTranscriptView? { homeView.transcript }
    private var conversation: ConversationID?
    private var focusGeneration = -1
    private var pendingFocus = false
    private var canTakeFocus = false
    private var stopped = false
    var onOpenConversation: (ConversationID) -> Void = { _ in }

    init(conversation: ConversationID?, isHome: Bool, defaults: UserDefaults = .standard) {
        self.conversation = conversation
        homeView = ChiefHomeView(defaults: defaults, conversation: conversation,
                                 remembersSelection: isHome)
        super.init(frame: .zero)
        clipsToBounds = true
        homeView.frame = bounds
        homeView.autoresizingMask = [.width, .height]
        homeView.onSelectConversation = { [weak self] id in
            guard let self else { return }
            self.conversation = id
            self.onOpenConversation(id)
        }
        addSubview(homeView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        guard canTakeFocus, let input = transcript?.primaryInput else { return false }
        return window?.makeFirstResponder(input) ?? false
    }

    /// A model update changes the conversation only when its identity changed.
    func show(_ conversation: ConversationID?) {
        guard !stopped, conversation != self.conversation else { return }
        self.conversation = conversation
        homeView.select(conversation ?? ChiefService.shared.defaultConversationID, notifySelection: false)
    }

    /// Hidden panes send no read receipts and cannot consume focus requests.
    func updatePresentation(visible: Bool, focused: Bool, generation: Int) {
        canTakeFocus = visible && focused
        homeView.isActive = visible
        if generation != focusGeneration {
            focusGeneration = generation
            pendingFocus = generation > 0
        }
        if canTakeFocus && pendingFocus { focusComposer() }
    }

    func focusComposer() {
        guard canTakeFocus, window != nil else { pendingFocus = true; return }
        pendingFocus = false
        // A click that focuses the Bonsplit pane may already have focused its
        // search or settings field. Keep that input instead of moving to compose.
        if var responder = window?.firstResponder as? NSView {
            if let editor = responder as? NSTextView, editor.isFieldEditor,
               let field = editor.delegate as? NSView { responder = field }
            if responder.isDescendant(of: homeView) { return }
        }
        homeView.focusComposer()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        homeView.isActive = false
        homeView.teardown()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        homeView.applyCurrentAppearance()
        if window != nil, canTakeFocus, pendingFocus || window?.firstResponder === self {
            focusComposer()
        }
    }
}
