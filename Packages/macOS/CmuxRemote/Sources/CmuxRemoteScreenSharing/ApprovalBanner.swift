// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CmuxDeviceHub
import Foundation

/// The approval banner for a device hub request (permission Ask), shown by
/// the Screen Sharing worker, so it appears with the cmux app quit too:
/// who asks and what it could do, Allow (remembered for that Mac) and Not
/// Now, with the device key and Allow Only This Time under Details. A floating,
/// non-activating panel at the top right of the main screen, over every app
/// (full-screen ones too); it never takes the keyboard or the frontmost app.
/// One request at a time, oldest first; it gives up after the protocol's
/// five minutes.
@MainActor
final class ApprovalBanner {
    private(set) var current: SessionRequest?
    private(set) var error: String?
    private var answering = false
    /// Details is open on the request on screen (closed again for the next request).
    private var detailsOpen = false
    private var settled: Set<String> = []
    private var panel: NSPanel?
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
        detailsOpen = false
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

    /// Details opens below the buttons; the panel keeps its top and grows downward.
    func toggleDetails() {
        detailsOpen.toggle()
        render()
    }

    // MARK: Panel

    private func render() {
        guard let request = current else {
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? Self.makePanel()
        self.panel = panel
        let content = ApprovalView(request: request, error: error, enabled: !answering, detailsOpen: detailsOpen,
                                   toggleDetails: { [weak self] in self?.toggleDetails() }) { [weak self, id = request.id] in self?.answer($0, for: id) }
        panel.contentView = content
        let size = content.fittingSize
        let area = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 600)
        panel.setFrame(CGRect(x: area.maxX - size.width - 16, y: area.maxY - size.height - 16, width: size.width, height: size.height),
                       display: true)
        // Over every app, without activating this one or taking the keyboard.
        panel.orderFrontRegardless()
    }

    static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: ApprovalView.width, height: 200),
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
        return panel
    }

    /// The banner's frame while it shows (status).
    var frame: CGRect? { panel?.isVisible == true ? panel?.frame : nil }
}

/// The banner's content (AppKit), as the app's Mac Screen prompt (`MacScreenApprovalView`): who
/// asks and what it could do, in plain words; Allow (the hub's Always at the scope asked for, so
/// this Mac is not asked again) and a quiet Not Now; Details opens below the buttons, so nothing
/// above them moves, with what Allow keeps, the asking device's key and Allow Only This Time.
/// Only a press on these buttons answers it.
@MainActor
final class ApprovalView: NSView {
    static let width: CGFloat = 360
    private let stack = NSStackView()
    private let request: SessionRequest
    private let error: String?
    private let enabled: Bool
    private let answer: (ApprovalChoice) -> Void
    private let detailsOpen: Bool
    private let toggle: () -> Void
    private var targets: [ApprovalButtonTarget] = []

    init(request: SessionRequest, error: String?, enabled: Bool, detailsOpen: Bool = false, toggleDetails: @escaping () -> Void = {},
         answer: @escaping (ApprovalChoice) -> Void) {
        self.detailsOpen = detailsOpen
        toggle = toggleDetails
        self.request = request
        self.error = error
        self.enabled = enabled
        self.answer = answer
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 160))
        let surface = NSVisualEffectView()
        surface.material = .popover
        surface.state = .active
        surface.wantsLayer = true
        surface.layer?.cornerRadius = 12
        surface.layer?.masksToBounds = true
        surface.setAccessibilityElement(true)
        surface.setAccessibilityRole(.group)
        surface.setAccessibilityIdentifier("macScreen.approval")
        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(stack)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor), surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor), surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: surface.leadingAnchor), stack.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            stack.topAnchor.constraint(equalTo: surface.topAnchor),
            widthAnchor.constraint(equalToConstant: Self.width),
        ])
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override var fittingSize: NSSize { NSSize(width: Self.width, height: ceil(stack.fittingSize.height)) }

    /// Details: the banner rebuilds its content with it open or closed.
    func toggleDetails() { toggle() }

    private func build() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        targets = []
        let full = request.scope == .full
        let fullWidth = Self.width - 32
        let textWidth = fullWidth - 40
        let glyph = NSImageView(image: NSImage(systemSymbolName: full ? "cursorarrow.and.square.on.square.dashed" : "eye",
                                               accessibilityDescription: nil) ?? NSImage())
        glyph.symbolConfiguration = .init(textStyle: .title2)
        glyph.contentTintColor = .controlAccentColor
        glyph.widthAnchor.constraint(equalToConstant: 28).isActive = true
        let title = Self.label(String(format: full
                ? RemoteText.t("macScreen.approval.titleFull", "%@ wants to control this Mac")
                : RemoteText.t("macScreen.approval.titleView", "%@ wants to see this Mac"), request.viewerName),
            style: .headline, wraps: true, width: textWidth)
        let body = Self.label(full ? RemoteText.t("macScreen.approval.bodyFull", "It can see your screen and use your mouse and keyboard.")
            : RemoteText.t("macScreen.approval.bodyView", "It can see your screen but can’t control it."),
            style: .body, color: .secondaryLabelColor, wraps: true, width: textWidth)
        let text = NSStackView(views: [title, body])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        let header = NSStackView(views: [glyph, text])
        header.orientation = .horizontal
        header.spacing = 12
        header.alignment = .top
        stack.addArrangedSubview(header)

        let details = button(RemoteText.t("macScreen.approval.details", "Details"), id: "details", quiet: true) { [weak self] in
            self?.toggleDetails()
        }
        details.setAccessibilityExpanded(detailsOpen)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let notNow = button(RemoteText.t("macScreen.approval.notNow", "Not Now"), id: ApprovalChoice.deny.rawValue) { [weak self] in
            self?.answer(.deny)
        }
        let allowChoice: ApprovalChoice = full ? .alwaysFull : .alwaysView
        let allow = button(RemoteText.t("macScreen.approval.allow", "Allow"), id: "allow") { [weak self] in self?.answer(allowChoice) }
        allow.keyEquivalent = "\r"
        let row = NSStackView(views: [details, spacer, notNow, allow])
        row.orientation = .horizontal
        row.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalToConstant: fullWidth).isActive = true

        // Below the buttons: what comes and goes never moves them.
        if let error {
            stack.addArrangedSubview(Self.label(error, style: .caption1, color: .systemRed, wraps: true, width: fullWidth))
        }
        if detailsOpen {
            stack.addArrangedSubview(Self.label(String(format: full
                    ? RemoteText.t("macScreen.approval.remembersFull", "Allow lets %@ control this Mac from now on. Change it in Devices.")
                    : RemoteText.t("macScreen.approval.remembersView", "Allow lets %@ see this Mac from now on. Change it in Devices."),
                request.viewerName), style: .caption1, color: .secondaryLabelColor, wraps: true, width: fullWidth))
            if let fingerprint = request.viewerKeyFingerprint {
                let caption = Self.label(RemoteText.t("macScreen.approval.deviceKey", "Device key"), style: .caption1, color: .tertiaryLabelColor)
                let code = Self.label(DeviceIdentity.displayFingerprint(fingerprint), style: .caption1, color: .secondaryLabelColor)
                code.font = .monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)
                code.isSelectable = true
                code.focusRingType = .none
                let line = NSStackView(views: [caption, code])
                line.orientation = .horizontal
                line.spacing = 6
                line.alignment = .firstBaseline
                stack.addArrangedSubview(line)
            }
            stack.addArrangedSubview(button(RemoteText.t("macScreen.approval.onlyThisTime", "Allow Only This Time"), id: ApprovalChoice.once.rawValue,
                                            quiet: true) { [weak self] in self?.answer(.once) })
        }
    }

    private func button(_ title: String, id: String, quiet: Bool = false, run: @escaping () -> Void) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.bezelStyle = quiet ? .accessoryBarAction : .push
        if quiet { button.isBordered = false; button.contentTintColor = .secondaryLabelColor }
        button.isEnabled = enabled
        button.setAccessibilityIdentifier("macScreen.approval.\(id)")
        let target = ApprovalButtonTarget(run)
        button.target = target
        button.action = #selector(ApprovalButtonTarget.press)
        targets.append(target)
        return button
    }

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
final class ApprovalButtonTarget: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func press() { run() }
}
