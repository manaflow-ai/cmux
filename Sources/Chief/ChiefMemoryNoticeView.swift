import AppKit
import CmuxChief
import CmuxHomeCore
import Observation

/// The transcript's "Chief will remember: prefers 14 pt font · Undo" row
/// (P1-5): a 10 pt centered system line that appears when Chief saves a note
/// while it works on this conversation (seen through ``ChiefMemoryStore``'s
/// file watcher, whoever wrote it: `cmux chief memory add` runs in Chief's
/// turn). Undo forgets the note. The row goes away on Undo, when the note is
/// forgotten elsewhere, or when the next turn starts.
///
/// MessagesLab's host `notice` row is text only, so this is a classic view the
/// transcript host places above the compose field; Undo is a real button
/// (keyboard and VoiceOver reachable).
@MainActor
final class ChiefMemoryNoticeView: NSView {
    private let conversation: ConversationID
    private let label = NSTextField(labelWithString: "")
    private let undoButton = NSButton(title: ChiefMemoryStrings.undo, target: nil, action: nil)
    private let row = NSStackView()
    private var fact: ChiefMemoryFact?
    private var wasWorking = false
    // SAFETY: written only on the main actor; `deinit` reads it once no other
    // reference exists, and NotificationCenter removal is thread-safe.
    nonisolated(unsafe) private var observer: (any NSObjectProtocol)?
    private var stopped = false

    /// The row appeared or went away: the host lays out again.
    var onChange: () -> Void = {}

    init(conversation: ConversationID) {
        self.conversation = conversation
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        isHidden = true
        label.font = .systemFont(ofSize: 10)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        undoButton.isBordered = false
        undoButton.font = .systemFont(ofSize: 10, weight: .semibold)
        undoButton.target = self
        undoButton.action = #selector(undo)
        undoButton.toolTip = ChiefMemoryStrings.undoHelp
        undoButton.setAccessibilityHelp(ChiefMemoryStrings.undoHelp)
        undoButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        row.orientation = .horizontal
        row.spacing = 4
        row.alignment = .firstBaseline
        row.edgeInsets = NSEdgeInsets(top: 2, left: 10, bottom: 2, right: 10)
        row.addArrangedSubview(label)
        row.addArrangedSubview(undoButton)
        addSubview(row)
        setAccessibilityElement(false)
        observer = NotificationCenter.default.addObserver(forName: ChiefMemoryStore.didChange, object: nil,
                                                          queue: .main) { [weak self] note in
            let added = note.userInfo?[ChiefMemoryStore.addedKey] as? [ChiefMemoryFact] ?? []
            MainActor.assumeIsolated { self?.memoryChanged(added: added) } // main-proof: observer on queue: .main
        }
        ChiefMemoryStore.shared.start()
        observeWorking()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // Not an isolated deinit (Swift 6.0 has none): removing the observer needs no actor.
    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Stops following the memory and the turn state (the transcript closed).
    func stop() {
        stopped = true
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    override var isFlipped: Bool { true }

    /// The row's size for `maxWidth` (zero while hidden).
    func preferredSize(maxWidth: CGFloat) -> CGSize {
        guard !isHidden else { return .zero }
        let fitting = row.fittingSize
        return CGSize(width: min(ceil(fitting.width), maxWidth), height: ceil(max(fitting.height, 18)))
    }

    override func layout() {
        super.layout()
        row.frame = bounds
    }

    func apply(_ theme: ChiefTheme) {
        label.textColor = theme.textSecondary
        undoButton.contentTintColor = theme.textPrimary
        undoButton.attributedTitle = NSAttributedString(string: ChiefMemoryStrings.undo, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: theme.textPrimary,
        ])
        layer?.backgroundColor = theme.opaqueBackground.withAlphaComponent(0.85).cgColor
    }

    // MARK: State

    private func memoryChanged(added: [ChiefMemoryFact]) {
        guard !stopped else { return }
        if let newest = added.last, ChiefService.shared.isWorking(conversation) {
            show(newest)
        } else if let fact, !ChiefMemoryStore.shared.facts.contains(where: { $0.id == fact.id }) {
            show(nil)
        }
    }

    /// Hides the row when this conversation's next turn starts (Observation, no polling).
    private func observeWorking() {
        guard !stopped else { return }
        let working = withObservationTracking {
            ChiefService.shared.isWorking(conversation)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeWorking() }
        }
        if working, !wasWorking, fact != nil { show(nil) }
        wasWorking = working
    }

    private func show(_ fact: ChiefMemoryFact?) {
        self.fact = fact
        isHidden = fact == nil
        if let fact {
            let text = ChiefMemoryStrings.willRemember(fact.text)
            label.stringValue = text + " ·"
            label.toolTip = fact.text
            label.setAccessibilityLabel(text)
            NSAccessibility.post(element: self, notification: .announcementRequested,
                                 userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
        needsLayout = true
        onChange()
    }

    @objc private func undo() {
        guard let fact else { return }
        if ChiefMemoryStore.shared.forget(fact.id) { show(nil) }
    }
}
