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
/// Allow, all standard dialog buttons (``CmuxDialogButtonView``). Non-activating:
/// showing it never takes the person's focus (socket focus policy); the person
/// clicks to answer. Closing the window, Escape, Deny or the time limit answer Deny.
///
/// SECURITY: only the person at this Mac answers Allow (review of #32983). The
/// agent that asked may also drive the screen (cmux Computer Use, any
/// computer-use tool), so, as macOS's own privacy prompts and Chrome's
/// permission prompts do:
/// - the panel is left out of screen capture and screen sharing
///   (`sharingType = .none`): a screenshot never shows the agent Allow;
/// - Allow answers only the person's own click, from the HID system
///   (``CmuxDialogPersonClick`` with the app's strict check): no
///   Accessibility press, programmatic click, key or posted click allows;
/// - a click that begins less than a double-click interval after the panel
///   shows or moves is not taken (Chrome's
///   `InputEventActivationProtector`), so a click aimed at what was there
///   before never allows.
/// Deny stays easy: its button and Escape, by anyone.
@MainActor
final class CookieImportConsentPanel {
    static let accessibilityID = "app.cookieImportConsent"
    /// How long the panel waits for an answer before it denies.
    static let limit: Duration = .seconds(180)

    private let request: CookieImportRequest
    let panel: CookieImportConsentWindow
    private let body = ThemeChangeView()
    private weak var parent: NSWindow?
    private var observers: [MainActorObservation] = []
    private var finish: ((CookieImportAnswer) -> Void)?
    /// Answers Deny once ``limit`` passes without an answer.
    private let deadline = DemandTimer(owner: "CookieImportConsentPanel.deadline")
    private let limitNote = NSTextField(labelWithString: "")
    /// Reveals the requester's tab (the person's click; nil when the requester has none).
    private let onShowRequester: (() -> Void)?
    /// The Allow button shown now: the panel reads the person's click on it, never its action.
    private(set) weak var allowButton: CmuxDialogButtonView?

    /// - Parameter isPersonEvent: Whether an event is the person's own input from the HID system (the app
    ///   passes `PersonInputCheck`); the default takes none, so Allow cannot answer.
    init(request: CookieImportRequest, onShowRequester: (() -> Void)?,
         isPersonEvent: @escaping @MainActor (NSEvent) -> Bool = { _ in false }) {
        self.request = request
        self.onShowRequester = onShowRequester
        panel = CookieImportConsentWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
                                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.personClick.isPersonEvent = isPersonEvent
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        // Out of every screenshot, recording and screen share: an agent that reads the screen never sees it.
        panel.sharingType = .none
        panel.contentView = makeContent()
        panel.allow = { [weak self] in self?.allowButton }
        panel.onPersonAllow = { [weak self] in self?.answer(.allow) }
    }

    /// Shows the panel on `window` and returns the person's answer (Deny on close or after ``limit``).
    func ask(on window: NSWindow, limit: Duration = CookieImportConsentPanel.limit) async -> CookieImportAnswer {
        await withCheckedContinuation { continuation in
            finish = { continuation.resume(returning: $0) }
            limitNote.stringValue = CookieImportStrings.deadline(Int(limit.components.seconds))
            show(on: window)
            deadline.schedule(after: limit) { @MainActor [weak self] in self?.answer(.timedOut) }
        }
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

        let showChat = CmuxDialogButtonView(standalone: CmuxDialogButton(
            id: "showChat", title: request.requester.kind == .terminal ? CookieImportStrings.showTerminal : CookieImportStrings.showAgentChat),
                                            target: self, action: #selector(showRequester))
        showChat.isEnabled = onShowRequester != nil
        showChat.setAccessibilityIdentifier(Self.accessibilityID + ".showChat")
        let deny = CmuxDialogButtonView(standalone: CmuxDialogButton(id: "deny", title: CookieImportStrings.deny, role: .cancel),
                                        target: self, action: #selector(deny))
        deny.setAccessibilityIdentifier(Self.accessibilityID + ".deny")
        // The default look with no key: a consent prompt never allows on Return (dialog-key-hints-AUDIT.md).
        let allow = CmuxDialogButtonView(CmuxDialogButton(id: "allow", title: CookieImportStrings.allow, role: .default), hint: nil,
                                         target: self, action: #selector(allowPressed))
        allow.setAccessibilityIdentifier(Self.accessibilityID + ".allow")
        allowButton = allow
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
        let glass = Glass.makeOverlayPanel(content: body, cornerRadius: Metrics.surfaceCornerRadius)
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
        box.cornerRadius = Metrics.insetCornerRadius
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = NSColor.textBackgroundColor.withAlphaComponent(0.35)
        box.contentViewMargins = NSSize(width: 10, height: 8)
        box.contentView = label
        box.setAccessibilityIdentifier(accessibilityID + "." + id)
        return box
    }

    private func show(on window: NSWindow) {
        parent = window
        window.addChildWindow(panel, ordered: .above)
        window.themeScope.adopt(panel)
        place()
        panel.arm()
        // Draws the person's eye without activating cmux (a Dock bounce while another app is in front).
        NSApp.requestUserAttention(.informationalRequest)
        let center = NotificationCenter.default
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            observers.append(MainActorObservation(name, object: window, center: center) { [weak self] in
                self?.place()
                // Moved under the pointer (AppKit moves a child window with its parent): armed again.
                self?.panel.arm()
            })
        }
        observers.append(MainActorObservation(NSWindow.willCloseNotification, object: window, center: center) { [weak self] in
            self?.answer(.deny)
        })
    }

    private func place() {
        guard let parent else { return }
        body.layoutSubtreeIfNeeded()
        let size = body.fittingSize
        let frame = parent.frame
        let placed = NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height)
        guard placed != panel.frame else { return }
        panel.setFrame(placed, display: true)
    }

    @objc private func showRequester() { onShowRequester?() }
    /// SECURITY: a press of Allow through its action (an Accessibility press, a programmatic click, a key)
    /// answers nothing: only the person's own click on Allow allows, read by the panel window from the
    /// click itself (``CookieImportConsentWindow``).
    @objc private func allowPressed() {}
    @objc private func deny() { answer(.deny) }

    /// The one answer: later clicks, the close and the deadline find `finish` gone.
    func answer(_ answer: CookieImportAnswer) {
        guard let finish else { return }
        self.finish = nil
        deadline.cancel()
        observers.removeAll()
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        finish(answer)
    }
}

/// The consent panel's window: the person's click on Allow is read from its own events
/// (``CmuxDialogPersonClick``), and only that click allows (``CookieImportConsentPanel``).
@MainActor
final class CookieImportConsentWindow: NSPanel {
    /// Chrome's guard against a click aimed at what was there before: a double-click interval.
    let personClick = CmuxDialogPersonClick(activationDelay: NSEvent.doubleClickInterval)
    /// The Allow button shown now (nil when none).
    var allow: @MainActor () -> NSControl? = { nil }
    /// Runs once per click of the person's on Allow.
    var onPersonAllow: @MainActor () -> Void = {}

    /// The frame the guard was last armed for.
    private var armedFrame: NSRect?

    override func sendEvent(_ event: NSEvent) {
        dispatch(event) { super.sendEvent(event) }
    }

    /// The panel shows or moves now (placed, or its parent moved): a click aimed at what was there
    /// before is not taken.
    func arm() {
        armedFrame = frame
        personClick.shown()
    }

    /// SECURITY: Allow answers here, from the person's click itself, never from the button's action. A
    /// mouse-down on a panel that moved since it was armed (an Accessibility client set its position) arms
    /// it again at that click, so that click is not taken.
    func dispatch(_ event: NSEvent, _ body: () -> Void) {
        if event.type == .leftMouseDown, frame != armedFrame {
            armedFrame = frame
            personClick.shown(at: event.timestamp)
        }
        if personClick.dispatch(event, allow: allow, in: windowNumber, body) { onPersonAllow() }
    }
}
