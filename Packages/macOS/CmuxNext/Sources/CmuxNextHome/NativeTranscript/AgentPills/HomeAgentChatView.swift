#if DEBUG
import AppKit
import CmuxNextDesign

/// DEBUG ONLY: one agent's chat in the Agent Messages Playground, the pane a pill opens (user 2026-11-03,
/// msg 19960 and the design in `plans/cmux-next/home-agent-pills-DESIGN.md`): a header with the agent's
/// title, status and Go to workspace; "Sent via Chief" over the task (Show more); "Worked for 5m 35s ›" over
/// its steps; its replies; and the shared composer, where each message names its sender (You or Chief) and
/// the Chief sees what the human sent. No "Take over" bar. A native mock of the real agent pane; the labels
/// are DEV-only English.
@MainActor
final class HomeAgentChatView: NSView {
    /// What the header's buttons do; nil hides the button.
    struct Actions {
        var goToWorkspace: (() -> Void)?
        /// The peek's Open: the chat moves to the right pane.
        var open: (() -> Void)?
        /// The pushed chat's back button.
        var back: (() -> Void)?
        /// The peek's close button.
        var close: (() -> Void)?
        /// A message sent from the composer (the playground also tells the Chief's chat).
        var sent: ((String) -> Void)?
    }

    private(set) var agent: HomeAgentPlaygroundAgent
    private let actions: Actions
    private let compact: Bool
    private let stack = NSStackView()
    private let scroll = NSScrollView()
    private let field = NSTextField()
    private var taskLabel: NSTextField?
    private var stepsLabel: NSTextField?

    /// - Parameters:
    ///   - compact: The peek's look: no composer, the task in two lines, the newest reply only.
    init(agent: HomeAgentPlaygroundAgent, compact: Bool = false, actions: Actions) {
        self.agent = agent
        self.compact = compact
        self.actions = actions
        super.init(frame: .zero)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Build

    private func build() {
        let header = makeHeader()
        let line = NSBox()
        line.boxType = .separator
        let document = FlippedView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        var views: [NSView] = [header, line, scroll]
        if !compact { views.append(makeComposer()) }
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        var constraints = [
            header.topAnchor.constraint(equalTo: topAnchor),
            line.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.topAnchor.constraint(equalTo: line.bottomAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ]
        for view in views {
            constraints.append(view.leadingAnchor.constraint(equalTo: leadingAnchor))
            constraints.append(view.trailingAnchor.constraint(equalTo: trailingAnchor))
        }
        if let composer = views.last, composer !== scroll {
            constraints.append(scroll.bottomAnchor.constraint(equalTo: composer.topAnchor))
            constraints.append(composer.bottomAnchor.constraint(equalTo: bottomAnchor))
        } else {
            constraints.append(scroll.bottomAnchor.constraint(equalTo: bottomAnchor))
        }
        NSLayoutConstraint.activate(constraints)
        fillTranscript()
    }

    private func makeHeader() -> NSView {
        let title = label(agent.title, size: TypeScale.body, weight: TypeScale.emphasis, color: .labelColor)
        let status = label("\(agent.peer) · \(agent.status)", size: TypeScale.caption, weight: TypeScale.regular, color: .secondaryLabelColor)
        let names = NSStackView(views: [title, status])
        names.orientation = .vertical
        names.alignment = .leading
        names.spacing = 1
        var views: [NSView] = []
        if let back = actions.back { views.append(button("‹ Chief", symbol: nil, action: back)) }
        views.append(names)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        views.append(spacer)
        if let go = actions.goToWorkspace { views.append(button("Go to workspace", symbol: "arrow.up.forward.app", action: go)) }
        if let open = actions.open { views.append(button("Open", symbol: "sidebar.right", action: open)) }
        if let close = actions.close { views.append(button("Close", symbol: "xmark", action: close)) }
        let header = NSStackView(views: views)
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 12)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return header
    }

    private func makeComposer() -> NSView {
        let box = HomeAgentFillView(fill: .quaternaryLabelColor.withAlphaComponent(0.12), radius: 18)
        field.placeholderString = "Message \(agent.peer) (the Chief sees it too)"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Typography.system(size: TypeScale.body)
        field.target = self
        field.action = #selector(send)
        let sendButton = NSButton(image: NSImage(systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: "Send") ?? NSImage(),
                                  target: self, action: #selector(send))
        sendButton.isBordered = false
        sendButton.contentTintColor = .controlAccentColor
        let row = NSStackView(views: [field, sendButton])
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(row)
        let holder = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(box)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: box.topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -8),
            box.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 12),
            box.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -12),
            box.topAnchor.constraint(equalTo: holder.topAnchor, constant: 8),
            box.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -12),
        ])
        return holder
    }

    private func fillTranscript() {
        if !agent.task.isEmpty {
            add(label("Sent via Chief", size: TypeScale.caption, weight: TypeScale.emphasis, color: .secondaryLabelColor), trailing: true)
            let task = label(agent.task, size: TypeScale.body, weight: TypeScale.regular, color: .labelColor, wraps: true)
            task.maximumNumberOfLines = compact ? 2 : 4
            taskLabel = task
            add(bubble(task), trailing: true, fraction: 0.85)
            add(link("Show more", action: #selector(toggleTask)), trailing: true)
        }
        if !agent.workedFor.isEmpty {
            add(link("\(agent.workedFor) ›", action: #selector(toggleSteps), color: .secondaryLabelColor))
            if !compact {
                let steps = label(agent.steps.map { "· " + $0 }.joined(separator: "\n"), size: TypeScale.detail, weight: TypeScale.regular,
                                  color: .secondaryLabelColor, wraps: true)
                steps.isHidden = true
                stepsLabel = steps
                add(steps)
            }
        }
        for message in compact ? Array(agent.messages.suffix(1)) : agent.messages { show(message) }
    }

    private func show(_ message: HomeAgentPlaygroundAgent.Message) {
        guard let sender = message.sender else {
            add(label(message.text, size: TypeScale.body, weight: TypeScale.regular, color: .labelColor, wraps: true), fraction: 1)
            return
        }
        // A message sent through the shared composer: its sender's name over a bubble on the right.
        add(label(sender, size: TypeScale.caption, weight: TypeScale.emphasis, color: sender == "Chief" ? .systemPurple : .controlAccentColor), trailing: true)
        add(bubble(label(message.text, size: TypeScale.body, weight: TypeScale.regular, color: .labelColor, wraps: true)), trailing: true, fraction: 0.85)
    }

    // MARK: Actions

    @objc private func send() {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        field.stringValue = ""
        let message = HomeAgentPlaygroundAgent.Message(sender: "You", text: text)
        agent.messages.append(message)
        show(message)
        actions.sent?(text)
        layoutSubtreeIfNeeded()
        scroll.documentView?.scroll(NSPoint(x: 0, y: scroll.documentView?.bounds.maxY ?? 0))
    }

    /// Types `text` into the composer and sends it (the playground's capture drive).
    func debugSend(_ text: String) {
        field.stringValue = text
        send()
    }

    @objc private func toggleTask(_ sender: NSButton) {
        guard let taskLabel else { return }
        let open = taskLabel.maximumNumberOfLines != 0
        taskLabel.maximumNumberOfLines = open ? 0 : (compact ? 2 : 4)
        sender.title = open ? "Show less" : "Show more"
    }

    @objc private func toggleSteps() { stepsLabel?.isHidden.toggle() }

    @objc private func runAction(_ sender: NSButton) { (sender as? ClosureButton)?.run?() }

    // MARK: Pieces

    private func add(_ view: NSView, trailing: Bool = false, fraction: CGFloat? = nil) {
        let row = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(view)
        stack.addArrangedSubview(row)
        var constraints = [
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            view.topAnchor.constraint(equalTo: row.topAnchor),
            view.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            trailing ? view.trailingAnchor.constraint(equalTo: row.trailingAnchor) : view.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            view.widthAnchor.constraint(lessThanOrEqualTo: row.widthAnchor, multiplier: fraction ?? 1),
        ]
        if fraction == 1 { constraints.append(view.widthAnchor.constraint(equalTo: row.widthAnchor)) }
        NSLayoutConstraint.activate(constraints)
    }

    private func bubble(_ text: NSTextField) -> NSView {
        let box = HomeAgentFillView(fill: .quaternaryLabelColor.withAlphaComponent(0.16), radius: 16)
        text.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            text.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            text.topAnchor.constraint(equalTo: box.topAnchor, constant: 8),
            text.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -8),
        ])
        return box
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, wraps: Bool = false) -> NSTextField {
        let field = wraps ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        field.font = Typography.system(size: size, weight: weight)
        field.textColor = color
        field.isSelectable = wraps
        if wraps { field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        return field
    }

    private func link(_ title: String, action: Selector, color: NSColor = .controlAccentColor) -> NSButton {
        let link = NSButton(title: title, target: self, action: action)
        link.isBordered = false
        link.font = Typography.system(size: TypeScale.detail, weight: TypeScale.emphasis)
        link.contentTintColor = color
        return link
    }

    private func button(_ title: String, symbol: String?, action: @escaping () -> Void) -> NSButton {
        let button = ClosureButton(title: title, target: nil, action: nil)
        button.run = action
        button.target = self
        button.action = #selector(runAction)
        button.bezelStyle = .push
        button.controlSize = .small
        if let symbol { button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); button.imagePosition = .imageLeading }
        return button
    }
}

/// A button that runs a closure (the header's actions).
private final class ClosureButton: NSButton {
    var run: (() -> Void)?
}

/// A top-down document view for the chat's scroll view.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
#endif
