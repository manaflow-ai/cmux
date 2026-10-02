public import AppKit
import CmuxNextDesign

/// The Home surface: the conversation list column, the open conversation's
/// transcript and the composer floating over its bottom edge. It renders
/// ``HomeViewModel`` and sends every intent through its `actions`. Becoming
/// first responder focuses the composer.
public final class HomeView: NSView {
    public let viewModel: HomeViewModel
    let list = ConversationListView()
    let transcript = TranscriptView()
    let composer = ComposerView()
    private let header = HomeHeaderView()
    private let separator = CALayer()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var loop: HomeObservationLoop?

    public init(viewModel: HomeViewModel) {
        self.viewModel = viewModel
        super.init(frame: .zero)
        wantsLayer = true
        separator.actions = RowLayer.noActions
        layer?.addSublayer(separator)
        emptyLabel.stringValue = HomeStrings.noConversation
        emptyLabel.alignment = .center
        for view in [list, transcript, header, composer, emptyLabel] as [NSView] { addSubview(view) }
        wire()
        loop = HomeObservationLoop { [weak self] in self?.sync() }
    }

    required init?(coder: NSCoder) { nil }

    isolated deinit { loop?.cancel() }

    public override var acceptsFirstResponder: Bool { true }

    /// Accepts focus, then hands it to the composer once AppKit finished
    /// installing this view as first responder (a nested makeFirstResponder
    /// inside becomeFirstResponder would be overwritten by the outer call).
    public override func becomeFirstResponder() -> Bool {
        // task-owner: one main-actor hop; nothing to cancel, it only moves focus inside this view
        Task { @MainActor [weak self] in
            guard let self, let window = self.window, window.firstResponder === self else { return }
            window.makeFirstResponder(self.composer.textView)
        }
        return true
    }

    private func wire() {
        list.onSelect = { [weak self] id in self?.viewModel.actions?.selectConversation(id) }
        list.onCreate = { [weak self] in self?.viewModel.actions?.createConversation() }
        composer.onSend = { [weak self] text, frame in self?.send(text, from: frame) }
        composer.onHeightChange = { [weak self] in self?.needsLayout = true }
        transcript.onTypingChange = { [weak self] ids in self?.viewModel.typingParticipantIDs = ids }
        transcript.onSawNewest = { [weak self] seq in
            guard let self, let id = self.viewModel.selectedConversationID else { return }
            self.viewModel.actions?.markRead(seq: seq, in: id)
        }
        transcript.onRetry = { [weak self] clientMsgID in
            guard let self, let id = self.viewModel.selectedConversationID else { return }
            self.viewModel.actions?.retry(clientMsgID: clientMsgID, in: id)
        }
    }

    /// Reads the view model (observation-tracked) and applies it.
    private func sync() {
        list.rows = viewModel.conversations
        list.selectedID = viewModel.selectedConversationID
        let source = viewModel.transcript
        if transcript.source !== source { transcript.source = source }
        let summary = viewModel.selectedConversation
        header.title = summary?.title ?? ""
        header.subtitle = summary.map(Self.subtitle) ?? ""
        let open = source != nil
        transcript.isHidden = !open
        composer.isHidden = !open
        header.isHidden = !open
        emptyLabel.isHidden = open
    }

    private static func subtitle(_ summary: HomeConversationSummary) -> String {
        let names = summary.participants.filter { !$0.isMe }.map(\.displayName).joined(separator: ", ")
        guard let owner = summary.ownerLabel else { return names }
        return names.isEmpty ? owner : "\(names) \u{00B7} \(owner)"
    }

    private func send(_ text: String, from frame: CGRect) {
        guard let id = viewModel.selectedConversationID else { return }
        let inTranscript = transcript.convert(frame, from: composer)
        // y-down transcript points for the flight
        let ghost = CGRect(x: inTranscript.minX, y: transcript.bounds.height - inTranscript.maxY,
                           width: inTranscript.width, height: inTranscript.height)
        transcript.prepareSendFlight(from: ghost, text: text)
        viewModel.actions?.send(text: text, replyTo: nil, in: id)
    }

    public override func layout() {
        super.layout()
        let listWidth = min(Metrics.sidebarWidth, max(160, bounds.width * 0.32))
        list.frame = CGRect(x: 0, y: 0, width: listWidth, height: bounds.height)
        let right = CGRect(x: listWidth, y: 0, width: bounds.width - listWidth, height: bounds.height)
        let headerHeight = Metrics.tabStripHeight + Metrics.space2
        header.frame = CGRect(x: right.minX, y: right.maxY - headerHeight, width: right.width, height: headerHeight)
        transcript.frame = CGRect(x: right.minX, y: 0, width: right.width, height: right.height - headerHeight)
        let inset = Metrics.panelInset
        let composerHeight = composer.preferredHeight
        composer.frame = CGRect(x: right.minX + inset, y: inset, width: max(1, right.width - 2 * inset), height: composerHeight)
        transcript.bottomInset = composerHeight + 2 * inset
        emptyLabel.frame = CGRect(x: right.minX, y: right.midY - 12, width: right.width, height: 24)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        separator.frame = CGRect(x: listWidth, y: 0, width: 1 / max(1, window?.backingScaleFactor ?? 2), height: bounds.height)
        CATransaction.commit()
        applyTheme()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    private func applyTheme() {
        performWithTheme {
            layer?.backgroundColor = Palette.windowBackground.cgColor
            separator.backgroundColor = Palette.separator.cgColor
            emptyLabel.font = Typography.body
            emptyLabel.textColor = Palette.textTertiary
        }
    }
}
