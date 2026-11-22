// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CmuxDeviceHub
import Darwin
import Foundation

/// The approval banner for a device hub request (permission Ask), shown by
/// the Screen Sharing worker, so it appears with the cmux app quit too: the
/// who asks and what it could do, and Allow (remembered for that Mac: the
/// hub's Always), Allow Only This Time and Not Now. A floating,
/// non-activating panel at the top right of the main screen, over every app
/// (full-screen ones too); it never takes the keyboard or the frontmost app.
/// One request at a time, oldest first; it gives up after the protocol's
/// five minutes.
@MainActor
final class ApprovalBanner {
    private(set) var current: SessionRequest?
    private(set) var error: String?
    private var answering = false
    private var settled: Set<String> = []
    private var panel: ApprovalPanel?
    private var expiry: Timer?
    /// PROTOCOL.md: a request expires after 5 minutes.
    var lifetime: TimeInterval = 300
    /// Answers a request (the hub's decide, then the permission to store).
    var decide: (SessionRequest, ApprovalChoice) async throws -> Void = { _, _ in }
    /// Called when the request on screen changes (the worker's status).
    var changed: () -> Void = {}

    /// The hub's pending requests changed: show the oldest unanswered one.
    func update(_ requests: [SessionRequest]) {
        let open = requests.filter { !settled.contains($0.id) }
        let next = open.first { $0.id == current?.id } ?? open.first
        guard next?.id != current?.id else { return }
        current = next
        error = nil
        answering = false
        expiry?.invalidate()
        expiry = nil
        if let next {
            // The protocol's own expiry for one request, invalidated when the request on screen changes.
            expiry = Timer.scheduledTimer(withTimeInterval: lifetime, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.current?.id == next.id else { return }
                    self.settled.insert(next.id)
                    self.update(requests)
                }
            }
        }
        render()
        changed()
    }

    /// Answers the request a button was drawn for: a click that lands after the next request took
    /// its place answers nothing.
    func answer(_ choice: ApprovalChoice, for requestID: String? = nil) {
        guard let request = current, requestID == nil || requestID == request.id, !answering else { return }
        answering = true
        render()
        Task { [weak self] in
            do {
                try await self?.decide(request, choice)
                self?.settle(request.id)
            } catch let failure as DeviceHubError where failure.code == .sessionNotPending || failure.code == .notFound {
                self?.settle(request.id)
            } catch {
                guard let self else { return }
                answering = false
                self.error = RemoteText.t("macScreen.approval.failed", "The answer did not reach the device hub. Try again.")
                render()
            }
        }
    }

    private func settle(_ id: String) {
        settled.insert(id)
        current = nil
        answering = false
        render()
        changed()
    }

    // MARK: Panel

    private func render() {
        guard let request = current else {
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? Self.makePanel()
        let entering = !panel.isVisible
        if panel.request != request.id {
            // A new request: a click aimed at what was there before it is not taken.
            panel.request = request.id
            panel.shown()
        }
        panel.onAllow = { [weak self, id = request.id] in self?.answer($0, for: id) }
        self.panel = panel
        let hadKeys = panel.isKeyWindow
        let content = ApprovalView(request: request, error: error, enabled: !answering) { [weak self, id = request.id] in self?.answer($0, for: id) }
        panel.contentView = content
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        let area = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 600)
        panel.setFrame(CGRect(x: area.maxX - size.width - ApprovalLook.screenMargin, y: area.maxY - size.height - ApprovalLook.screenMargin,
                              width: size.width, height: size.height), display: true)
        if hadKeys { panel.makeFirstResponder(content) }
        panel.invalidateShadow()
        // Over every app, without activating this one or taking the keyboard.
        panel.orderFrontRegardless()
        if entering { ApprovalLook.enter(content) }
    }

    static func makePanel() -> ApprovalPanel {
        let panel = ApprovalPanel(contentRect: CGRect(x: 0, y: 0, width: ApprovalView.width, height: 200),
                                  styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        return panel
    }

    /// The banner's frame while it shows (status).
    var frame: CGRect? { panel?.isVisible == true ? panel?.frame : nil }
}

/// The banner's window: it shows without taking the keyboard or the frontmost app, and a click into the card gives
/// it the keys (Escape denies, Tab moves). SECURITY: an Allow answers only the person's own click on it, read here
/// from the click's events, never from the button's action or a key, as the app's join consent does
/// (`CmuxDialogPersonClick`): an Accessibility press, a programmatic click, a key, or a click another process posts
/// (a computer-use agent, a script) allows no device to see or control this Mac. A click begun within the
/// double-click interval of the banner showing, or of the person's previous click, is not taken.
@MainActor
final class ApprovalPanel: NSPanel {
    /// The request shown (a redraw of the same request keeps ``shown(at:)``).
    var request: String?
    /// Answers an Allow the person clicked.
    var onAllow: (ApprovalChoice) -> Void = { _ in }
    /// Whether an event is the person's own input (``ApprovalPersonInput``); tests replace it.
    var isPersonEvent: (NSEvent) -> Bool = { ApprovalPersonInput.isPerson($0) }
    /// The event the app is handling now (tests set it).
    var eventInHand: () -> NSEvent? = { NSApp.currentEvent }
    private var shownAt: TimeInterval = .infinity
    private var lastDown: TimeInterval?
    /// The person's mouse-down on an Allow, held until its click ends.
    private var held: (event: NSEvent, button: ApprovalButton, choice: ApprovalChoice)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// The banner shows a request now: a click begun before `uptime` plus the double-click interval is not taken.
    func shown(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        shownAt = uptime
        held = nil
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, !isKeyWindow, let content = contentView {
            makeKey()
            makeFirstResponder(content)
        }
        dispatch(event) { super.sendEvent(event) }
    }

    /// The panel's own dispatch of `event` (`body`); the person's click that ends on an Allow answers it, once.
    func dispatch(_ event: NSEvent, _ body: () -> Void) {
        switch event.type {
        case .leftMouseDown:
            held = nil
            if isPersonEvent(event) {
                let delay = NSEvent.doubleClickInterval
                let settled = event.timestamp >= shownAt + delay && lastDown.map { event.timestamp >= $0 + delay } ?? true
                lastDown = event.timestamp
                if settled, let (button, choice) = allow(at: event) { held = (event, button, choice) }
            }
            body()
            // A button's tracking loop may take the mouse-up inside the mouse-down's dispatch.
            if let up = eventInHand(), up.type == .leftMouseUp { endClick(up) }
        case .leftMouseDragged, .pressure:
            body()
        case .leftMouseUp:
            body()
            endClick(event)
        default:
            held = nil
            body()
        }
    }

    private func allow(at event: NSEvent) -> (ApprovalButton, ApprovalChoice)? {
        guard let view = contentView as? ApprovalView, event.windowNumber == windowNumber else { return nil }
        return view.allows.first { button, _ in
            button.isEnabled && button.bounds.contains(button.convert(event.locationInWindow, from: nil))
        }
    }

    private func endClick(_ up: NSEvent) {
        guard let held else { return }
        self.held = nil
        let button = held.button
        guard isPersonEvent(up), up.windowNumber == windowNumber, up.timestamp >= held.event.timestamp, button.isEnabled,
              button.window === self, button.bounds.contains(button.convert(up.locationInWindow, from: nil)) else { return }
        onAllow(held.choice)
    }
}

/// The strict check for the person's own input, as the app's `PersonInputCheck`: only the HID system's events
/// count (source state the HID system's, source process 0 or the WindowServer), never a click another process
/// posts or this one makes.
enum ApprovalPersonInput {
    static let windowServer = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer"

    static func isPerson(_ event: NSEvent) -> Bool {
        guard let cgEvent = event.cgEvent,
              cgEvent.getIntegerValueField(.eventSourceStateID) == Int64(CGEventSourceStateID.hidSystemState.rawValue) else { return false }
        let source = cgEvent.getIntegerValueField(.eventSourceUnixProcessID)
        if source == 0 { return true }
        guard source > 0, source != Int64(getpid()), let pid = pid_t(exactly: source) else { return false }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        return String(cString: buffer) == windowServer
    }
}

/// The banner's look: the cmux dialog card's (CmuxNext's `CmuxDialogView` on `CmuxDialogCardSurface`), drawn here
/// with AppKit alone because this worker links no cmux design module. Keep the numbers in step with
/// `CmuxDialogMetrics`: a 16 pt padding, buttons 26 pt tall rounding 8 pt, the card rounding 24 pt (concentric: the
/// button's corner plus the padding), 4 pt between buttons, 12 pt above them.
@MainActor
enum ApprovalLook {
    static let padding: CGFloat = 16
    static let spacing: CGFloat = 8
    static let subtitleGap: CGFloat = 4
    static let buttonsGap: CGFloat = 12
    static let buttonGap: CGFloat = 4
    static let buttonHeight: CGFloat = 26
    static let buttonCorner: CGFloat = 8
    static var cardCorner: CGFloat { buttonCorner + padding }
    static let iconSize: CGFloat = 40
    static let iconGap: CGFloat = 12
    static let keycapInset: CGFloat = 3
    static let keycapPadding: CGFloat = 5
    static let screenMargin: CGFloat = 12
    static let titleFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
    static let bodyFont = NSFont.systemFont(ofSize: 13)
    static let captionFont = NSFont.systemFont(ofSize: 11)
    static let codeFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static let keycapFont = NSFont.systemFont(ofSize: 11, weight: .semibold)

    /// The card's material: Liquid Glass on macOS 26 and later, the popover blur before; both turn opaque under
    /// Reduce Transparency on their own.
    static func card(content: NSView) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cardCorner
            glass.contentView = content
            return glass
        }
        let blur = NSVisualEffectView()
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = cardCorner
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
        blur.layer?.borderWidth = 0.5
        blur.layer?.borderColor = NSColor.separatorColor.cgColor
        content.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: blur.leadingAnchor), content.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            content.topAnchor.constraint(equalTo: blur.topAnchor), content.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])
        return blur
    }

    /// Fades the card in, a short ease-out, as a cmux overlay card opens; at once under Reduce Motion.
    @MainActor
    static func enter(_ view: NSView) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer = view.layer else { return }
        // motion: allow this worker links no cmux motion gate; Reduce Motion is honored above
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.18
        fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
        layer.add(fade, forKey: "enter")
    }
}

/// The banner's content (AppKit), as the cmux dialog card draws a request and as the app's Mac Screen prompt words
/// it: the app icon at the left; who asks, what it can do and what Allow keeps, the asking device's key on an inset
/// well, a failed answer; then three answers stacked the card's width: Allow (the hub's Always at the scope asked
/// for, so this Mac is not asked again), Allow Only This Time, and Not Now last as quiet red text (Escape).
/// SECURITY: only the person's own click answers an Allow (``ApprovalPanel``); any press or Escape denies.
@MainActor
final class ApprovalView: NSView {
    static let width: CGFloat = 432
    private let answer: (ApprovalChoice) -> Void
    private let stack = NSStackView()
    private(set) var buttons: [ApprovalButton] = []
    /// The two Allows and what each answers (``ApprovalPanel`` reads the person's click on them).
    private(set) var allows: [(ApprovalButton, ApprovalChoice)] = []

    init(request: SessionRequest, error: String?, enabled: Bool, answer: @escaping (ApprovalChoice) -> Void) {
        self.answer = answer
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 200))
        wantsLayer = true
        let look = ApprovalLook.self
        let textWidth = Self.width - look.padding * 2 - look.iconSize - look.iconGap
        let content = NSView()
        let card = look.card(content: content)
        card.setAccessibilityElement(true)
        card.setAccessibilityRole(.group)
        card.setAccessibilityIdentifier("macScreen.approval")
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)
        icon.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(icon)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = look.spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor), card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor), card.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: Self.width),
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: look.padding),
            icon.topAnchor.constraint(equalTo: content.topAnchor, constant: look.padding),
            icon.widthAnchor.constraint(equalToConstant: look.iconSize), icon.heightAnchor.constraint(equalToConstant: look.iconSize),
            stack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: look.iconGap),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: look.padding),
            stack.widthAnchor.constraint(equalToConstant: textWidth),
            content.bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: look.padding),
        ])
        let title = Self.label(String(format: request.scope == .full
                ? RemoteText.t("macScreen.approval.titleFull", "%@ wants to control this Mac")
                : RemoteText.t("macScreen.approval.titleView", "%@ wants to see this Mac"), request.viewerName),
            font: look.titleFont, width: textWidth)
        stack.addArrangedSubview(title)
        stack.setCustomSpacing(look.subtitleGap, after: title)
        let full = request.scope == .full
        stack.addArrangedSubview(Self.label(full
                ? RemoteText.t("macScreen.approval.bodyFull", "It can see your screen and use your mouse and keyboard.")
                : RemoteText.t("macScreen.approval.bodyView", "It can see your screen but can’t control it."),
            font: look.bodyFont, color: .secondaryLabelColor, width: textWidth))
        stack.addArrangedSubview(Self.label(String(format: full
                ? RemoteText.t("macScreen.approval.remembersFull", "Allow lets %@ control this Mac from now on. Change it in Devices.")
                : RemoteText.t("macScreen.approval.remembersView", "Allow lets %@ see this Mac from now on. Change it in Devices."),
            request.viewerName), font: look.bodyFont, color: .secondaryLabelColor, width: textWidth))
        if let fingerprint = request.viewerKeyFingerprint {
            stack.addArrangedSubview(Self.label(RemoteText.t("macScreen.approval.deviceKey", "Device key"), font: look.captionFont,
                                                color: .secondaryLabelColor, width: textWidth))
            stack.addArrangedSubview(CodeWell(Self.fingerprintLines(fingerprint), width: textWidth))
        }
        if let error {
            let line = Self.label(error, font: look.captionFont, color: .systemRed, width: textWidth)
            line.setAccessibilityIdentifier("macScreen.approval.error")
            stack.addArrangedSubview(line)
        }
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(look.buttonsGap, after: last) }
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = look.buttonGap
        // Allow remembers this Mac (the hub's Always at the scope asked for), so the next request is not asked.
        let order: [(ApprovalChoice, String, ApprovalButton.Role, String?)] = [
            (full ? .alwaysFull : .alwaysView, RemoteText.t("macScreen.approval.allow", "Allow"), .primary, nil),
            (.once, RemoteText.t("macScreen.approval.onlyThisTime", "Allow Only This Time"), .secondary, nil),
            (.deny, RemoteText.t("macScreen.approval.notNow", "Not Now"), .quietDestructive, "esc"),
        ]
        for (choice, label, role, key) in order {
            // SECURITY: an Allow's own action answers nothing; Not Now takes any press.
            let button = ApprovalButton(label, role: role, key: key) { if choice == .deny { answer(choice) } }
            if choice != .deny { allows.append((button, choice)) }
            button.isEnabled = enabled
            button.setAccessibilityIdentifier("macScreen.approval.\(choice.rawValue)")
            column.addArrangedSubview(button)
            button.widthAnchor.constraint(equalToConstant: textWidth).isActive = true
            buttons.append(button)
        }
        stack.addArrangedSubview(column)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    /// Escape denies, once the person clicked into the card (the panel then has the keys). SECURITY: no key allows.
    override func keyDown(with event: NSEvent) {
        guard buttons.first?.isEnabled == true, event.keyCode == 53 else { return super.keyDown(with: event) }
        answer(.deny)
    }

    override func cancelOperation(_ sender: Any?) {
        if buttons.first?.isEnabled == true { answer(.deny) }
    }

    override var fittingSize: NSSize {
        layoutSubtreeIfNeeded()
        return NSSize(width: Self.width, height: ceil(stack.fittingSize.height) + ApprovalLook.padding * 2)
    }

    /// The fingerprint in two lines of four groups, to compare group by group against the other device's.
    static func fingerprintLines(_ fingerprint: String) -> String {
        let groups = DeviceIdentity.displayFingerprint(fingerprint).split(separator: " ")
        let half = (groups.count + 1) / 2
        return [groups.prefix(half), groups.dropFirst(half)].filter { !$0.isEmpty }
            .map { $0.joined(separator: " ") }.joined(separator: "\n")
    }

    static func label(_ text: String, font: NSFont, color: NSColor = .labelColor, width: CGFloat) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = font
        field.textColor = color
        field.preferredMaxLayoutWidth = width
        field.isSelectable = false
        return field
    }
}

/// A code to compare (the fingerprint): monospaced digits on a faint well of the text's own ink with a hairline edge,
/// rounded as the buttons are; selectable, so it can be copied.
@MainActor
final class CodeWell: NSView {
    init(_ text: String, width: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        let code = ApprovalView.label(text, font: ApprovalLook.codeFont, width: width - 20)
        code.isSelectable = true
        code.setAccessibilityLabel(text.replacingOccurrences(of: "\n", with: " "))
        code.translatesAutoresizingMaskIntoConstraints = false
        addSubview(code)
        NSLayoutConstraint.activate([
            code.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            code.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            bottomAnchor.constraint(equalTo: code.bottomAnchor, constant: 7),
            widthAnchor.constraint(equalToConstant: width),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.cornerRadius = ApprovalLook.buttonCorner
            layer?.cornerCurve = .continuous
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
            layer?.borderWidth = contrast ? 1 : 1 / max(window?.backingScaleFactor ?? 2, 1)
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(contrast ? 0.5 : 0.12).cgColor
        }
    }
}

/// One answer, as the cmux dialog's button draws it: the primary a solid fill of the label color, a secondary a faint gray, Deny red text with no fill at rest (Escape). A held button changes only its
/// fill. The keyboard focus ring is the system's.
@MainActor
final class ApprovalButton: NSButton {
    enum Role { case primary, secondary, quietDestructive }
    let role: Role
    private let run: () -> Void
    private let keycap: NSTextField?
    private let plate = CALayer()
    private var hovering = false { didSet { needsDisplay = true } }

    init(_ title: String, role: Role, key: String?, run: @escaping () -> Void) {
        self.role = role
        self.run = run
        keycap = key.map { NSTextField(labelWithString: $0) }
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        bezelStyle = .regularSquare
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        target = self
        action = #selector(press)
        setAccessibilityLabel(title)
        heightAnchor.constraint(equalToConstant: ApprovalLook.buttonHeight).isActive = true
        if let keycap {
            keycap.font = ApprovalLook.keycapFont
            keycap.alignment = .center
            keycap.setAccessibilityElement(false)
            addSubview(keycap)
            layer?.addSublayer(plate)
            setAccessibilityHelp("Escape")
        }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    @objc private func press() { run() }

    /// The key its keycap shows (nil: none).
    var keycapText: String? { keycap?.stringValue }

    override var isEnabled: Bool { didSet { needsDisplay = true } }
    override var isHighlighted: Bool { didSet { needsDisplay = true } }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override var wantsUpdateLayer: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private var ink: NSColor {
        switch role {
        case .primary: .textBackgroundColor
        case .secondary: .labelColor
        case .quietDestructive: .systemRed
        }
    }

    override func updateLayer() {
        let step: CGFloat = isHighlighted ? 2 : hovering ? 1 : 0
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let fill: NSColor = switch role {
            case .primary: NSColor.labelColor.blended(withFraction: step * 0.08, of: .textBackgroundColor) ?? .labelColor
            case .secondary: NSColor.labelColor.withAlphaComponent(0.08 + step * 0.04)
            case .quietDestructive: NSColor.systemRed.withAlphaComponent(step * 0.08)
            }
            layer?.backgroundColor = fill.cgColor
            layer?.cornerRadius = ApprovalLook.buttonCorner
            layer?.cornerCurve = .continuous
            plate.backgroundColor = ink.withAlphaComponent(0.12).cgColor
            plate.cornerRadius = ApprovalLook.buttonCorner - ApprovalLook.keycapInset
            plate.cornerCurve = .continuous
            keycap?.textColor = ink.withAlphaComponent(0.75)
            attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: ink, .font: role == .primary ? NSFont.systemFont(ofSize: 13, weight: .semibold) : ApprovalLook.bodyFont,
            ])
        }
        alphaValue = isEnabled ? 1 : 0.45
    }

    override func layout() {
        super.layout()
        guard let keycap else { return }
        let inset = ApprovalLook.keycapInset
        let size = keycap.intrinsicContentSize
        let height = bounds.height - inset * 2
        let width = max(height, ceil(size.width) + ApprovalLook.keycapPadding * 2)
        let frame = NSRect(x: bounds.maxX - inset - width, y: inset, width: width, height: height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        plate.frame = frame
        CATransaction.commit()
        keycap.frame = NSRect(x: frame.minX, y: frame.midY - ceil(size.height) / 2, width: width, height: ceil(size.height))
    }
}
