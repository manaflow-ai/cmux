// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CmuxDeviceHub
import Foundation

/// The approval banner for a device hub request (permission Ask), shown by
/// the Screen Sharing worker, so it appears with the cmux app quit too: the
/// asking device's name and key fingerprint, the scope, and Deny, Allow Once,
/// Always Allow View Only, Always Allow Full Control. A floating,
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
    private var panel: NSPanel?
    private var expiry: DispatchWorkItem?
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
        expiry?.cancel()
        expiry = nil
        if let next {
            let work = DispatchWorkItem { [weak self] in
                guard let self, current?.id == next.id else { return }
                settled.insert(next.id)
                update(requests)
            }
            expiry = work
            // The protocol's own expiry for one request, cancelled when it is answered.
            DispatchQueue.main.asyncAfter(deadline: .now() + lifetime, execute: work)
        }
        render()
        changed()
    }

    func answer(_ choice: ApprovalChoice) {
        guard let request = current, !answering else { return }
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
        self.panel = panel
        let content = ApprovalView(request: request, error: error, enabled: !answering) { [weak self] in self?.answer($0) }
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

/// The banner's content (AppKit): a rounded popup surface with the request
/// and its four answers. Only a press on these buttons answers it.
@MainActor
final class ApprovalView: NSView {
    static let width: CGFloat = 380
    private let stack = NSStackView()

    init(request: SessionRequest, error: String?, enabled: Bool, answer: @escaping (ApprovalChoice) -> Void) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 200))
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
        let glyph = NSImageView(image: NSImage(systemSymbolName: request.scope == .full ? "cursorarrow.and.square.on.square.dashed" : "eye",
                                               accessibilityDescription: nil) ?? NSImage())
        glyph.symbolConfiguration = .init(textStyle: .title3)
        glyph.contentTintColor = .controlAccentColor
        let title = Self.label(String(format: request.scope == .full
                ? RemoteText.t("macScreen.approval.titleFull", "%@ wants to control this Mac")
                : RemoteText.t("macScreen.approval.titleView", "%@ wants to see this Mac"), request.viewerName),
            style: .headline, wraps: true, width: textWidth - 34)
        let header = NSStackView(views: [glyph, title])
        header.orientation = .horizontal
        header.spacing = 10
        header.alignment = .centerY
        stack.addArrangedSubview(header)
        stack.addArrangedSubview(Self.label(String(format: RemoteText.t("macScreen.approval.scope", "Asks for %@."), request.scope.remoteTitle),
                                            style: .body, color: .secondaryLabelColor))
        if let fingerprint = request.viewerKeyFingerprint {
            let caption = Self.label(RemoteText.t("macScreen.approval.fingerprint", "Device key fingerprint"), style: .caption1,
                                     color: .secondaryLabelColor)
            let code = Self.label(DeviceIdentity.displayFingerprint(fingerprint), style: .body)
            code.font = .monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular)
            code.isSelectable = true
            let column = NSStackView(views: [caption, code])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 2
            stack.addArrangedSubview(column)
        }
        if let error {
            stack.addArrangedSubview(Self.label(error, style: .caption1, color: .systemRed, wraps: true, width: textWidth))
        }
        func button(_ choice: ApprovalChoice, primary: Bool = false, destructive: Bool = false) -> NSButton {
            let button = NSButton(title: choice.title, target: nil, action: nil)
            button.bezelStyle = .push
            button.isEnabled = enabled
            button.setAccessibilityIdentifier("macScreen.approval.\(choice.rawValue)")
            if primary { button.keyEquivalent = "\r" }
            if destructive { button.hasDestructiveAction = true }
            let target = ApprovalButtonTarget { answer(choice) }
            button.target = target
            button.action = #selector(ApprovalButtonTarget.press)
            targets.append(target)
            return button
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let first = NSStackView(views: [button(.deny, destructive: true), spacer, button(.once, primary: true)])
        first.orientation = .horizontal
        first.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(first)
        first.widthAnchor.constraint(equalToConstant: textWidth).isActive = true
        let second = NSStackView(views: [button(.alwaysView), button(.alwaysFull)])
        second.orientation = .horizontal
        stack.addArrangedSubview(second)
    }

    private var targets: [ApprovalButtonTarget] = []

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
final class ApprovalButtonTarget: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func press() { run() }
}
