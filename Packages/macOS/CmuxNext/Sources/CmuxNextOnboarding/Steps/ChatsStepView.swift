import AppKit
import CmuxNextDesign

/// Chats: one dense line per chat (`ChatRow`), newest first, and a key hint.
/// ↑ and ↓ move the cursor and Space checks the chat under it; every other
/// key (Return, Escape) goes on to the flow.
final class ChatsStepView: NSView {
    private let model: ChatsStepModel
    private let list = NSStackView()
    private let scroll = NSScrollView()
    private let status = OnboardingLabel.make(font: OnboardingMetrics.captionFont, color: Palette.textTertiary, lines: 2)
    private let empty = OnboardingLabel.make(OnboardingStrings.chatsEmpty, color: Palette.textSecondary, lines: 2)
    private var rows: [ChatRow] = []
    private var shown: [AgentChat]?
    private var shownCursor: Int?
    private var listHeight: NSLayoutConstraint?
    private var loop: RenderLoop?

    init(model: ChatsStepModel) {
        self.model = model
        super.init(frame: .zero)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        list.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(list)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        empty.isHidden = true
        let stack = NSStackView(views: [scroll, empty, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 6),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -6),
            list.topAnchor.constraint(equalTo: document.topAnchor, constant: 2), list.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -2),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            empty.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        listHeight = scroll.heightAnchor.constraint(equalToConstant: 0)
        listHeight?.isActive = true
        loop = RenderLoop { [weak self] in self?.render() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 126: model.moveCursor(-1)
        case 125: model.moveCursor(1)
        case 49: model.toggleAtCursor()
        default: super.keyDown(with: event)
        }
    }

    private func render() {
        let chats = model.chats
        if chats != shown {
            shown = chats
            shownCursor = nil
            list.arrangedSubviews.forEach { $0.removeFromSuperview() }
            let now = Date()
            rows = chats.map { chat in
                let row = ChatRow(chat: chat, now: now) { [weak model] in model?.toggle(chat) }
                list.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
                return row
            }
        }
        for (index, chat) in chats.enumerated() {
            rows[index].update(checked: model.isSelected(chat), cursor: index == model.cursor)
        }
        if model.cursor != shownCursor, rows.indices.contains(model.cursor) {
            shownCursor = model.cursor
            rows[model.cursor].scrollToVisible(rows[model.cursor].bounds)
        }
        // As tall as the rows, up to twelve and a half: the half row says the list scrolls.
        listHeight?.constant = min(CGFloat(chats.count), 12.5) * ChatRow.height + 4
        let nothing = model.scanned && chats.isEmpty
        scroll.isHidden = nothing
        empty.isHidden = !nothing
        status.stringValue = model.isScanning ? OnboardingStrings.chatsScanning : (chats.isEmpty ? "" : OnboardingStrings.chatsKeys)
    }
}
