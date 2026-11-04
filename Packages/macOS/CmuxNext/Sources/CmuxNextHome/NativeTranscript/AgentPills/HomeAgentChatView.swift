import AppKit
import CmuxNextDesign

/// One agent's chat in the agent pane, the tab a pill opens (user 2026-11-03, msg 19960 and
/// `plans/cmux-next/home-agent-pills-DESIGN.md`): a header with the agent's title, status and Go to
/// workspace; "Sent via Chief" over the task (Show more); "Worked for 5m 35s ›" over when it started and
/// ended; then every later message, the Chief's named. No "Take over" bar. The DEBUG Agent Messages
/// Playground draws its made-up agents here too, with its DEV-only back, open, close and composer controls.
@MainActor
final class HomeAgentChatView: NSView {
    /// What the header's buttons do; nil hides the button. Only Go to workspace ships; the rest are the DEBUG playground's.
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

    private(set) var content: HomeAgentChatContent
    private let actions: Actions
    private let compact: Bool
    private let stack = NSStackView()
    private let scroll = NSScrollView()
    private let field = NSTextField()
    private var taskLabel: NSTextField?
    private var stepsLabel: NSTextField?

    /// - Parameters:
    ///   - compact: The peek's look: no composer, the task in two lines, the newest reply only.
    init(content: HomeAgentChatContent, compact: Bool = false, actions: Actions) {
        self.content = content
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
        #if DEBUG
        if !compact, actions.sent != nil { views.append(makeComposer()) }
        #endif
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
        let title = label(content.title, size: TypeScale.body, weight: TypeScale.emphasis, color: .labelColor)
        let status = label("\(content.peer) · \(content.status)", size: TypeScale.caption, weight: TypeScale.regular, color: .secondaryLabelColor)
        let names = NSStackView(views: [title, status])
        names.orientation = .vertical
        names.alignment = .leading
        names.spacing = 1
        var views: [NSView] = []
        #if DEBUG
        if let back = actions.back { views.append(button("‹ Chief", symbol: nil, action: back)) }
        #endif
        views.append(names)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        views.append(spacer)
        if let go = actions.goToWorkspace {
            let title = String(localized: "home.agentPane.goToWorkspace", defaultValue: "Go to workspace", bundle: .module)
            let goButton = button(title, symbol: "arrow.up.forward.app", action: go)
            goButton.setAccessibilityIdentifier("home.agentPane.goToWorkspace")
            goToWorkspaceButton = goButton
            views.append(goButton)
        }
        #if DEBUG
        if let open = actions.open { views.append(button("Open", symbol: "sidebar.right", action: open)) }
        if let close = actions.close { views.append(button("Close", symbol: "xmark", action: close)) }
        #endif
        let header = NSStackView(views: views)
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 12)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return header
    }

    #if DEBUG
    /// DEBUG playground only: the shared composer (slice 3 ships it); DEV-only English.
    private func makeComposer() -> NSView {
        let box = HomeAgentFillView(fill: .quaternaryLabelColor.withAlphaComponent(0.12), radius: 18)
        field.placeholderString = "Message \(content.peer) (the Chief sees it too)"
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
    #endif

    /// The task's lines before Show more.
    private var taskLines: Int { compact ? 2 : 4 }

    private func fillTranscript() {
        if !content.task.isEmpty {
            let sent = String(localized: "home.agentPane.sentViaChief", defaultValue: "Sent via Chief", bundle: .module)
            add(label(sent, size: TypeScale.caption, weight: TypeScale.emphasis, color: .secondaryLabelColor), trailing: true)
            let task = label(content.task, size: TypeScale.body, weight: TypeScale.regular, color: .labelColor, wraps: true)
            task.maximumNumberOfLines = taskLines
            taskLabel = task
            add(bubble(task), trailing: true, fraction: 0.85)
            add(link(Self.showMore, action: #selector(toggleTask)), trailing: true)
        }
        if !content.workedFor.isEmpty {
            add(link("\(content.workedFor) ›", action: #selector(toggleSteps), color: .secondaryLabelColor))
            if !compact, !content.details.isEmpty {
                let steps = label(content.details.map { "· " + $0 }.joined(separator: "\n"), size: TypeScale.detail, weight: TypeScale.regular,
                                  color: .secondaryLabelColor, wraps: true)
                steps.isHidden = true
                stepsLabel = steps
                add(steps)
            }
        }
        for message in compact ? Array(content.messages.suffix(1)) : content.messages { show(message) }
    }

    private static var showMore: String { String(localized: "home.agentPane.showMore", defaultValue: "Show more", bundle: .module) }
    private static var showLess: String { String(localized: "home.agentPane.showLess", defaultValue: "Show less", bundle: .module) }

    private func show(_ message: HomeAgentChatContent.Message) {
        guard let sender = message.sender.label else {
            add(label(message.text, size: TypeScale.body, weight: TypeScale.regular, color: .labelColor, wraps: true), fraction: 1)
            return
        }
        // A message the Chief (or the person) sent the agent: its sender's name over a bubble on the right.
        let color: NSColor = message.sender == .chief ? .systemPurple : .controlAccentColor
        add(label(sender, size: TypeScale.caption, weight: TypeScale.emphasis, color: color), trailing: true)
        add(bubble(label(message.text, size: TypeScale.body, weight: TypeScale.regular, color: .labelColor, wraps: true)), trailing: true, fraction: 0.85)
    }

    // MARK: Actions

    #if DEBUG
    @objc private func send() {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        field.stringValue = ""
        let message = HomeAgentChatContent.Message(sender: .you, text: text)
        content.messages.append(message)
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
    #endif

    /// True when the chat has the shared composer (tests).
    var hasComposer: Bool { field.superview != nil }

    /// Types `text` into the composer and sends it, as the person does (tests, the playground's capture drive).
    func sendFromComposer(_ text: String) {
        #if DEBUG
        debugSend(text)
        #endif
    }

    /// Shows `content` in place: the composer keeps what the person is typing (red stub).
    func update(_ content: HomeAgentChatContent) {
    }

    /// The header's Go to workspace button; nil when the content has no workspace link (tests).
    private(set) var goToWorkspaceButton: NSButton?

    /// True while the whole task shows (after Show more).
    var isTaskExpanded: Bool { taskLabel?.maximumNumberOfLines == 0 }

    /// Show more and Show less: the whole task, or its first lines again.
    @objc func toggleTask(_ sender: NSButton) {
        guard let taskLabel else { return }
        let open = taskLabel.maximumNumberOfLines != 0
        taskLabel.maximumNumberOfLines = open ? 0 : taskLines
        sender.title = open ? Self.showLess : Self.showMore
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
