import AppKit
import CmuxNextDesign
import CmuxNextWakeups
import CmuxNextCompat

/// The consent panel of an agent's cookie import: a glass panel centered on a
/// shell window (a child window, so it stays above Chromium page windows),
/// shown before anything of the other browser is read. It names the agent as
/// a reference (its chat or terminal tab, by name; a click reveals that tab),
/// shows the agent's reason and its latest message large and first, then the
/// source, the sites and the target profile, with Show Agent Chat, Deny and
/// Allow. Non-activating: showing it never takes the person's focus (socket
/// focus policy); the person clicks to answer. Closing the window, Escape or
/// the time limit answer Deny. The answer resolves the run's ``FirstOutcome``, which its import awaits off main.
@MainActor
final class CookieImportConsentPanel {
    static let accessibilityID = "app.cookieImportConsent"
    /// How long the panel waits for an answer before it denies.
    static let limit: Duration = .seconds(180)

    private let request: CookieImportRequest
    private let panel: NSPanel
    private let body = ThemeChangeView()
    private weak var parent: NSWindow?
    /// The panel's size, measured once when it shows: its text never changes after, so a window
    /// resize or move only moves it.
    private var size: CGSize = .zero
    /// The parent window's move, resize and close, through its one ``WindowEvents`` fan-out.
    private var subscriptions: [EventSubscription] = []
    /// Where the one answer goes; a panel released without one answers Deny.
    private let outcome: FirstOutcome<CookieImportAnswer>
    private var answered = false
    /// Answers Deny once ``limit`` passes without an answer. `automation`: the agent's request waits on it, no view.
    private let deadline: MainDeadline
    private let limitNote = NSTextField(labelWithString: "")
    /// Reveals the requester's tab (the person's click; nil when the requester has none).
    private let onShowRequester: (() -> Void)?

    /// - Parameters:
    ///   - request: What the agent asks for.
    ///   - deadlines: The app's one deadline placer (the limit).
    ///   - answer: Resolved once with the person's answer.
    ///   - onShowRequester: Reveals the requester's tab; nil when it has none.
    init(request: CookieImportRequest, deadlines: MainDeadlineScheduler, answer: FirstOutcome<CookieImportAnswer>,
         onShowRequester: (() -> Void)?) {
        self.request = request
        self.onShowRequester = onShowRequester
        outcome = answer
        deadline = MainDeadline(owner: "CookieImportConsentPanel.deadline", workClass: .automation, scheduler: deadlines)
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = makeContent()
    }

    // A panel that goes away without an answer denies (the outcome is Sendable; a later resolve is dropped).
    nonisolated deinit {
        outcome.resolve(.deny)
    }

    /// Shows the panel on `window`; the person's answer resolves the outcome (Deny on close or after ``limit``).
    func show(on window: NSWindow, limit: Duration = CookieImportConsentPanel.limit) {
        limitNote.stringValue = CookieImportStrings.deadline(Int(limit.components.seconds))
        present(on: window)
        deadline.schedule(after: limit) { [weak self] in self?.answer(.timedOut) }
    }

    var isShown: Bool { panel.parent != nil }

    private func makeContent() -> NSView {
        let title = NSTextField(labelWithString: CookieImportStrings.title)
        title.font = .systemFont(ofSize: TypeScale.title, weight: TypeScale.emphasis)
        let lead = Self.wrapping(CookieImportStrings.lead(browser: request.source), size: TypeScale.detail)

        // The reference to the agent: a borderless text button (not a link) that reveals its tab.
        let reference = NSButton(title: request.requester.reference, target: self, action: #selector(showRequester))
        reference.isBordered = false
        reference.font = .systemFont(ofSize: TypeScale.detail, weight: TypeScale.emphasis)
        reference.isEnabled = onShowRequester != nil
        reference.setAccessibilityIdentifier(Self.accessibilityID + ".requester")
        var requesterViews: [NSView] = [Self.caption(CookieImportStrings.requestedBy), reference]
        if let workspace = request.requester.workspace, !workspace.isEmpty {
            requesterViews.append(Self.wrapping(CookieImportStrings.inWorkspace(workspace), size: TypeScale.detail, secondary: true))
        }
        let requester = NSStackView(views: requesterViews)
        requester.spacing = 6

        // The agent's reason, large and boxed: the first thing the person reads.
        let reason = Self.boxed(Self.wrapping(request.reason, size: TypeScale.field, weight: TypeScale.emphasis), id: "reason")
        var views: [NSView] = [title, lead, requester, Self.caption(CookieImportStrings.reasonLabel), reason]
        if let latest = request.requester.latestMessage, !latest.isEmpty {
            views.append(Self.caption(CookieImportStrings.latestLabel))
            views.append(Self.boxed(Self.wrapping(latest, size: TypeScale.detail, secondary: true), id: "latest"))
        }
        let sites = request.domains.isEmpty ? CookieImportStrings.allSites : request.domains.joined(separator: ", ")
        let grid = NSGridView(views: [
            [Self.caption(CookieImportStrings.fromLabel), Self.wrapping(request.source, size: TypeScale.detail)],
            [Self.caption(CookieImportStrings.sitesLabel), Self.wrapping(sites, size: TypeScale.detail)],
            [Self.caption(CookieImportStrings.intoLabel), Self.wrapping(request.target, size: TypeScale.detail)],
        ])
        grid.rowSpacing = 4
        grid.columnSpacing = 10
        views.append(grid)
        views.append(Self.wrapping(request.sourceIsSafari ? CookieImportStrings.afterAllowSafari : CookieImportStrings.afterAllow,
                                   size: TypeScale.caption, secondary: true))

        let showChat = ThemedBezelButton(title: request.requester.kind == .terminal ? CookieImportStrings.showTerminal : CookieImportStrings.showAgentChat,
                                         target: self, action: #selector(showRequester))
        showChat.isEnabled = onShowRequester != nil
        showChat.setAccessibilityIdentifier(Self.accessibilityID + ".showChat")
        let deny = ThemedBezelButton(title: CookieImportStrings.deny, target: self, action: #selector(deny))
        deny.keyHint = .escape
        deny.setAccessibilityIdentifier(Self.accessibilityID + ".deny")
        let allow = NSButton(title: CookieImportStrings.allow, target: self, action: #selector(allow))
        allow.setAccessibilityIdentifier(Self.accessibilityID + ".allow")
        limitNote.font = .systemFont(ofSize: TypeScale.caption)
        limitNote.textColor = .secondaryLabelColor
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [showChat, limitNote, spacer, deny, allow])
        buttons.spacing = 8
        views.append(buttons)

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 14, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [lead, reason, buttons, grid] { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36).isActive = true }
        if let latest = views.first(where: { $0.accessibilityIdentifier() == Self.accessibilityID + ".latest" }) {
            latest.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36).isActive = true
        }
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
            stack.widthAnchor.constraint(equalToConstant: 460),
        ])
        let glass = Glass.makeOverlayPanel(content: body, cornerRadius: 14)
        glass.setAccessibilityIdentifier(Self.accessibilityID)
        glass.setAccessibilityLabel(CookieImportStrings.title)
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

    private static func boxed(_ label: NSTextField, id: String) -> NSView {
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 8
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = NSColor.textBackgroundColor.withAlphaComponent(0.35)
        box.contentViewMargins = NSSize(width: 10, height: 8)
        box.contentView = label
        box.setAccessibilityIdentifier(accessibilityID + "." + id)
        return box
    }

    private func present(on window: NSWindow) {
        parent = window
        window.addChildWindow(panel, ordered: .above)
        window.themeScope.adopt(panel)
        // sync-layout: fittingSize below measures the wrapping labels at their laid-out width.
        body.layoutSubtreeIfNeeded()
        size = body.fittingSize
        place()
        // Draws the person's eye without activating cmux (a Dock bounce while another app is in front).
        NSApp.requestUserAttention(.informationalRequest)
        let events = WindowEvents.of(window)
        subscriptions = [
            events.subscribe(NSWindow.didResizeNotification, owner: "CookieImportConsentPanel.place") { [weak self] in self?.place() },
            events.subscribe(NSWindow.didMoveNotification, owner: "CookieImportConsentPanel.place") { [weak self] in self?.place() },
            events.subscribe(NSWindow.willCloseNotification, owner: "CookieImportConsentPanel.close") { [weak self] in self?.answer(.deny) },
        ]
    }

    private func place() {
        guard let parent else { return }
        let frame = parent.frame
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height),
                       display: true)
    }

    @objc private func showRequester() { onShowRequester?() }
    @objc private func allow() { answer(.allow) }
    @objc private func deny() { answer(.deny) }

    /// The one answer: later clicks, the close and the deadline find it given.
    func answer(_ answer: CookieImportAnswer) {
        guard !answered else { return }
        answered = true
        deadline.cancel()
        subscriptions.removeAll()
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        outcome.resolve(answer)
    }
}
