import AppKit
import CmuxNextDesign
import CmuxNextWakeups

/// One shown team invite confirmation and its single answer (``TeamInviteConsentPanel`` shows one at a time).
@MainActor
final class TeamInviteConsentWindow {
    private let request: TeamInviteRequest
    private let panel: NSPanel
    private let body = ThemeChangeView()
    private weak var parent: NSWindow?
    private var finish: ((TeamInviteAnswer) -> Void)?
    /// Answers Don't Send once the limit passes; an answer cancels it.
    private let deadline = DemandTimer(owner: "TeamInviteConsentPanel.deadline")
    private let limitNote = NSTextField(labelWithString: "")
    private let onShowRequester: (() -> Void)?

    init(request: TeamInviteRequest, onShowRequester: (() -> Void)?) {
        self.request = request
        self.onShowRequester = onShowRequester
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 260),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = makeContent()
    }

    func ask(on window: NSWindow, limit: Duration) async -> TeamInviteAnswer {
        await withCheckedContinuation { continuation in
            finish = { continuation.resume(returning: $0) }
            limitNote.stringValue = TeamInviteStrings.deadline(Int(limit.components.seconds))
            show(on: window)
            // A bounded deadline that is the intended behavior: no answer in time sends nothing; an answer cancels it.
            deadline.schedule(after: limit) { @MainActor [weak self] in self?.answer(.timedOut) }
        }
    }

    private func makeContent() -> NSView {
        let id = TeamInviteConsentPanel.accessibilityID
        let title = NSTextField(labelWithString: TeamInviteStrings.title)
        title.font = .systemFont(ofSize: TypeScale.title, weight: TypeScale.emphasis)
        let lead = Self.wrapping(TeamInviteStrings.lead(team: request.team.name), size: TypeScale.detail)

        let reference = NSButton(title: request.requester.reference, target: self, action: #selector(showRequester))
        reference.isBordered = false
        reference.font = .systemFont(ofSize: TypeScale.detail, weight: TypeScale.emphasis)
        reference.isEnabled = onShowRequester != nil
        reference.setAccessibilityIdentifier(id + ".requester")
        let requester = NSStackView(views: [Self.caption(TeamInviteStrings.requestedBy), reference])
        requester.spacing = 6

        let reasonText = request.reason.isEmpty ? TeamInviteStrings.noReason : request.reason
        let reason = Self.wrapping(reasonText, size: TypeScale.field, weight: TypeScale.emphasis, secondary: request.reason.isEmpty)
        reason.setAccessibilityIdentifier(id + ".reason")
        let role = request.role == .admin ? TeamInviteStrings.roleAdmin : TeamInviteStrings.roleMember
        let to = Self.wrapping(request.emails.joined(separator: ", "), size: TypeScale.detail, weight: TypeScale.emphasis)
        to.setAccessibilityIdentifier(id + ".to")
        let grid = NSGridView(views: [
            [Self.caption(TeamInviteStrings.toLabel), to],
            [Self.caption(TeamInviteStrings.teamLabel), Self.wrapping(request.team.name, size: TypeScale.detail)],
            [Self.caption(TeamInviteStrings.roleLabel), Self.wrapping(role, size: TypeScale.detail)],
        ])
        grid.rowSpacing = 4
        grid.columnSpacing = 10

        let showRequester = ThemedBezelButton(title: request.requester.kind == .terminal ? TeamInviteStrings.showTerminal : TeamInviteStrings.showAgentChat,
                                              target: self, action: #selector(showRequester))
        showRequester.isEnabled = onShowRequester != nil
        showRequester.isHidden = request.requester.kind == .unknown
        let deny = ThemedBezelButton(title: TeamInviteStrings.deny, target: self, action: #selector(deny))
        deny.keyHint = .escape
        deny.setAccessibilityIdentifier(id + ".deny")
        let send = NSButton(title: TeamInviteStrings.send, target: self, action: #selector(allow))
        send.setAccessibilityIdentifier(id + ".send")
        limitNote.font = .systemFont(ofSize: TypeScale.caption)
        limitNote.textColor = .secondaryLabelColor
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [showRequester, limitNote, spacer, deny, send])
        buttons.spacing = 8

        let views: [NSView] = [title, lead, requester, Self.caption(TeamInviteStrings.reasonLabel), reason, grid, buttons]
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 14, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [lead, reason, grid, buttons] { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36).isActive = true }
        body.addSubview(stack)
        body.onThemeChange = { [weak title, weak reference] in
            title?.textColor = Palette.textPrimary
            reference?.contentTintColor = Palette.accent
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            stack.topAnchor.constraint(equalTo: body.topAnchor),
            stack.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: 440),
        ])
        let glass = Glass.makeOverlayPanel(content: body, cornerRadius: 14)
        glass.setAccessibilityIdentifier(id)
        glass.setAccessibilityLabel(TeamInviteStrings.title)
        return glass
    }

    private static func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: TypeScale.caption, weight: TypeScale.emphasis)
        label.textColor = .secondaryLabelColor
        return label
    }

    private static func wrapping(_ text: String, size: CGFloat, weight: NSFont.Weight = TypeScale.regular, secondary: Bool = false) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = secondary ? .secondaryLabelColor : .labelColor
        label.isSelectable = true
        label.focusRingType = .none
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }

    private func show(on window: NSWindow) {
        parent = window
        window.addChildWindow(panel, ordered: .above)
        window.themeScope.adopt(panel)
        place()
        // Draws the person's eye without activating cmux (a Dock bounce while another app is in front).
        NSApp.requestUserAttention(.informationalRequest)
        // A child window moves with its parent; no window observer is needed.
    }

    private func place() {
        guard let parent else { return }
        body.layoutSubtreeIfNeeded()
        let size = body.fittingSize
        let frame = parent.frame
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height),
                       display: true)
    }

    @objc private func showRequester() { onShowRequester?() }
    @objc private func allow() { answer(.allow) }
    @objc private func deny() { answer(.deny) }

    /// The one answer: later clicks, the close and the deadline find `finish` gone.
    func answer(_ answer: TeamInviteAnswer) {
        guard let finish else { return }
        self.finish = nil
        deadline.cancel()
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        finish(answer)
    }
}
