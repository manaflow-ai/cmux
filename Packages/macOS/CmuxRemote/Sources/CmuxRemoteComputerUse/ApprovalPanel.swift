// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation

/// The engine's `ask` (cmux_computer_use.h): a cmux Remote approval panel, "<Agent> wants to use
/// <App>", with Allow Once, Allow for This Session, Always Allow <App> and Deny (and Never when the
/// mode remembers answers). A floating, non-activating panel at the top right of the main screen,
/// over every app and Space; it never takes the keyboard or the frontmost app, so only a click on
/// its buttons answers it. Questions queue, oldest first. Nobody answering in `timeout` answers
/// `unavailable` (the engine refuses the call). (CmuxRemote has no access to the app's key-hint
/// dialog components, so the buttons are AppKit push buttons in the Screen Sharing banner's style.)
@MainActor
final class ApprovalPanel {
    nonisolated static let timeout: TimeInterval = 120

    private struct Pending {
        let id: Int
        let question: ApprovalQuestion
        let answer: @Sendable (ApprovalAnswer) -> Void
    }

    private var queue: [Pending] = []
    private var nextID = 0
    private var panel: NSPanel?
    private var expiry: Timer?

    /// Shows `question` (after any open one); `answer` is called exactly once.
    func ask(_ question: ApprovalQuestion, answer: @escaping @Sendable (ApprovalAnswer) -> Void) {
        nextID += 1
        queue.append(Pending(id: nextID, question: question, answer: answer))
        if queue.count == 1 { present() }
    }

    /// Answers every open question `unavailable` (the worker is stopping).
    func cancelAll() {
        let open = queue
        queue.removeAll()
        expiry?.invalidate()
        panel?.orderOut(nil)
        for pending in open { pending.answer(.unavailable) }
    }

    var openCount: Int { queue.count }

    private func present() {
        expiry?.invalidate()
        guard let current = queue.first else {
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? Self.makePanel()
        self.panel = panel
        let view = ApprovalQuestionView(question: current.question) { [weak self] choice in self?.settle(current.id, choice) }
        panel.contentView = view
        let size = view.fittingSize
        let area = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 600)
        panel.setFrame(CGRect(x: area.maxX - size.width - 16, y: area.maxY - size.height - 16, width: size.width, height: size.height),
                       display: true)
        panel.orderFrontRegardless()
        // The question's own lifetime (2 minutes), replaced when the next question shows.
        expiry = Timer.scheduledTimer(withTimeInterval: Self.timeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.settle(current.id, .unavailable) }
        }
    }

    private func settle(_ id: Int, _ choice: ApprovalAnswer) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let pending = queue.remove(at: index)
        pending.answer(choice)
        if index == 0 { present() }
    }

    static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: ApprovalQuestionView.width, height: 160),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        // An agent must never see (or click) the question about itself.
        panel.sharingType = .none
        return panel
    }
}

/// The question's content: a rounded popover surface, the cmux Remote glyph tint, the title,
/// one line of detail and the answers.
@MainActor
final class ApprovalQuestionView: NSView {
    static let width: CGFloat = 400
    private let stack = NSStackView()
    private var targets: [ApprovalPressTarget] = []

    init(question: ApprovalQuestion, answer: @escaping (ApprovalAnswer) -> Void) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 160))
        let surface = NSVisualEffectView()
        surface.material = .popover
        surface.state = .active
        surface.wantsLayer = true
        surface.layer?.cornerRadius = 12
        surface.layer?.masksToBounds = true
        surface.setAccessibilityElement(true)
        surface.setAccessibilityRole(.group)
        surface.setAccessibilityIdentifier("computerUse.approval")
        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(stack)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor), surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor), surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: surface.leadingAnchor), stack.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            stack.topAnchor.constraint(equalTo: surface.topAnchor), stack.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
            widthAnchor.constraint(equalToConstant: Self.width),
        ])
        let textWidth = Self.width - 32
        let glyph = NSImageView(image: NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: nil) ?? NSImage())
        glyph.symbolConfiguration = .init(textStyle: .title3)
        glyph.contentTintColor = AgentCursorOverlay.blue
        let title = Self.label(ComputerUseText.approvalTitle(question), style: .headline, wraps: true, width: textWidth - 34)
        let header = NSStackView(views: [glyph, title])
        header.orientation = .horizontal
        header.spacing = 10
        header.alignment = .centerY
        stack.addArrangedSubview(header)
        stack.addArrangedSubview(Self.label(ComputerUseText.approvalDetail(question), style: .body, color: .secondaryLabelColor,
                                            wraps: true, width: textWidth))
        func button(_ choice: ApprovalAnswer) -> NSButton {
            let button = NSButton(title: ComputerUseText.choice(choice, app: question.appName), target: nil, action: nil)
            button.bezelStyle = .push
            button.controlSize = .regular
            button.setAccessibilityIdentifier("computerUse.approval.\(choice)")
            if choice == .allowOnce { button.keyEquivalent = "\r" }
            if choice == .deny || choice == .never { button.hasDestructiveAction = true }
            let target = ApprovalPressTarget { answer(choice) }
            button.target = target
            button.action = #selector(ApprovalPressTarget.press)
            targets.append(target)
            return button
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        var refuse = [button(.deny)]
        if question.remember { refuse.insert(button(.never), at: 0) }
        let first = NSStackView(views: refuse + [spacer, button(.allowOnce)])
        first.orientation = .horizontal
        first.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(first)
        first.widthAnchor.constraint(equalToConstant: textWidth).isActive = true
        var lasting = [button(.allowSession)]
        if question.remember { lasting.append(button(.always)) }
        let second = NSStackView(views: lasting)
        second.orientation = .horizontal
        stack.addArrangedSubview(second)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var fittingSize: NSSize { NSSize(width: Self.width, height: ceil(stack.fittingSize.height)) }

    static func label(_ text: String, style: NSFont.TextStyle, color: NSColor = .labelColor, wraps: Bool = false,
                      width: CGFloat? = nil) -> NSTextField {
        let field = wraps ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        field.font = .preferredFont(forTextStyle: style)
        field.textColor = color
        if let width { field.preferredMaxLayoutWidth = width }
        return field
    }
}

/// An NSButton's target that runs a closure.
@MainActor
final class ApprovalPressTarget: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func press() { run() }
}
