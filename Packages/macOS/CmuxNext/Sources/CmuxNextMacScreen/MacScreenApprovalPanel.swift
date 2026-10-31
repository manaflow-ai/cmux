import AppKit
import CmuxNextCompat
import CmuxNextDesign
public import CmuxNextDevices
import CmuxNextWakeups
public import Observation

/// The host's approval prompt for a device hub request (permission Ask):
/// the viewer device's name and key fingerprint and the scope it asks for,
/// with Deny, Allow Once, Always Allow View Only and Always Allow Full
/// Control. A floating, non-activating panel at the top right of the main
/// screen: it shows over every app (full-screen ones too) and never takes
/// the keyboard or the frontmost app from the person. One request at a
/// time, in arrival order; a request the hub ends (revoked, timed out)
/// leaves the panel, and the panel gives up after the protocol's five
/// minutes on its own.
@MainActor @Observable
public final class MacScreenApprovalPrompt {
    /// The request on screen.
    public private(set) var current: SessionRequest?
    /// The last answer failed (the request ended meanwhile, the network).
    public private(set) var error: String?
    public private(set) var answering = false
    /// How long a request may wait (PROTOCOL.md: requests expire after 5 min).
    @ObservationIgnored var lifetime: Duration = .seconds(300)
    @ObservationIgnored var hub: @MainActor () -> DeviceHub? = { nil }
    /// Requests answered or expired here, which the hub may still list for a moment.
    @ObservationIgnored private var settled: Set<String> = []
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private let expiry = DemandTimer(owner: "mac-screen.approval-expiry")
    @ObservationIgnored private var watch: Task<Void, Never>?
    /// Shows and hides the panel; tests replace it.
    @ObservationIgnored var present: @MainActor (Bool) -> Void = { _ in }

    public init() {
        present = { [weak self] visible in self?.setPanelVisible(visible) }
    }

    /// Follows `hub`'s pending requests from now on (nil: none).
    func follow(_ hub: DeviceHub?) {
        watch?.cancel()
        watch = nil
        settled = []
        update(hub?.pendingRequests ?? [])
        guard let hub else { return }
        watch = Task { [weak self] in
            for await requests in ObservationStream({ hub.pendingRequests }) {
                guard !Task.isCancelled else { return }
                self?.update(requests)
            }
        }
    }

    /// The hub's pending requests changed: show the oldest unanswered one.
    func update(_ requests: [SessionRequest]) {
        let open = requests.filter { !settled.contains($0.id) }
        let next = open.first { $0.id == current?.id } ?? open.first
        guard next?.id != current?.id else { return }
        current = next
        error = nil
        answering = false
        expiry.cancel()
        if let next {
            expiry.schedule(after: lifetime) { @MainActor [weak self] in
                guard let self, current?.id == next.id else { return }
                settled.insert(next.id)
                update(self.hub()?.pendingRequests ?? [])
            }
        }
        present(next != nil)
    }

    /// One of the prompt's buttons.
    public func answer(_ choice: MacScreenApprovalChoice) {
        guard let request = current, let hub = hub(), !answering else { return }
        answering = true
        let (decision, scope, thenPermission) = choice.answer(requested: request.scope)
        // task-owner: one decision for the request on screen; the next request shows when it settles
        Task { [weak self] in
            do {
                try await hub.decide(request, decision: decision, scope: scope)
                if let thenPermission {
                    try await hub.setPermission(host: hub.identity.id, viewer: request.viewerId, scope: thenPermission)
                }
                self?.settle(request.id, hub: hub)
            } catch let failure as DeviceHubError where failure.code == .sessionNotPending || failure.code == .notFound {
                // It ended meanwhile (cancelled by the viewer, expired): nothing to answer.
                self?.settle(request.id, hub: hub)
            } catch {
                guard let self else { return }
                answering = false
                self.error = L.t("macScreen.approval.failed", "The answer did not reach the device hub. Try again.")
            }
        }
    }

    func settle(_ id: String, hub: DeviceHub) {
        settled.insert(id)
        // Keep the old request until update observes the transition to no request. Clearing it
        // here made update's nil == nil guard skip closing the last request's panel.
        update(hub.pendingRequests)
    }

    // MARK: Panel

    /// Where the prompt's panel shows; nil while hidden (tests).
    var panelFrame: CGRect? { panel?.isVisible == true ? panel?.frame : nil }

    private func setPanelVisible(_ visible: Bool) {
        guard visible, current != nil else {
            // Closed, not only ordered out: its content holds this prompt, so an ordered-out panel
            // stayed in the app's window list for good. The next request makes a fresh one.
            panel?.close()
            panel = nil
            return
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // A fresh content view per request, measured before it shows.
        let content = MacScreenApprovalView(prompt: self)
        content.onResize = { [weak self, weak content] in
            guard let self, let content, self.panel?.contentView === content else { return }
            place(content)
        }
        panel.contentView = content
        place(content)
        // Over every app, without activating this one or taking the keyboard.
        panel.orderFrontRegardless()
    }

    /// Sizes the panel to `content` at the top right of the main screen.
    private func place(_ content: MacScreenApprovalView) {
        guard let panel else { return }
        var size = content.fittingSize
        if size.width < 300 || size.height < 100 { size = CGSize(width: max(size.width, 380), height: max(size.height, 220)) }
        let screen = NSScreen.main ?? NSScreen.screens.first
        let area = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: size.width + 32, height: size.height + 32)
        panel.setFrame(CGRect(x: area.maxX - size.width - 16, y: area.maxY - size.height - 16, width: size.width, height: size.height),
                       display: true)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 380, height: 200),
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
}

/// The prompt's content, in the app theme (AppKit): who asks, for what, the
/// asking device's key fingerprint, a failed answer, and the four answers.
/// Only a press on these buttons (a person at this Mac) answers from here.
@MainActor
final class MacScreenApprovalView: MacScreenThemedView {
    /// What the prompt shows.
    struct Shown: Equatable {
        var request: SessionRequest?
        var error: String?
        var answering: Bool
        /// The type scale the prompt was built at (`MacScreenType.sizes`).
        var typeSizes = MacScreenType.sizes
    }

    static let width: CGFloat = 380
    private static let textWidth = width - 32

    /// The fitting size changed (an error line came or went).
    var onResize: @MainActor () -> Void = {}
    private let prompt: MacScreenApprovalPrompt
    private let background = MacScreenFill(\.popup, shape: .rounded(Metrics.panelCornerRadius), bordered: true)
    private let stack = MacScreenStack.make(.vertical, spacing: 10, alignment: .leading,
                                            insets: NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16))
    private var buttons: [MacScreenButton] = []
    private(set) var shown: Shown?

    init(prompt: MacScreenApprovalPrompt) {
        self.prompt = prompt
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 200))
        background.translatesAutoresizingMaskIntoConstraints = true
        background.autoresizingMask = [.width, .height]
        background.setAccessibilityElement(true)
        background.setAccessibilityRole(.group)
        background.setAccessibilityIdentifier("macScreen.approval")
        addSubview(background)
        background.addSubview(stack)
        let trailing = stack.trailingAnchor.constraint(equalTo: background.trailingAnchor)
        let bottom = stack.bottomAnchor.constraint(equalTo: background.bottomAnchor)
        trailing.priority = .init(999)
        bottom.priority = .init(999)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.widthAnchor.constraint(equalToConstant: Self.width),
            trailing,
            bottom,
        ])
        render()
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        background.frame = bounds
    }

    /// The prompt's size: its width, and the height of its content at that width.
    override var fittingSize: NSSize {
        guard shown?.request != nil else { return .zero }
        return NSSize(width: Self.width, height: ceil(stack.fittingSize.height))
    }

    private func render() {
        let next = withObservationTracking {
            Shown(request: prompt.current, error: prompt.error, answering: prompt.answering)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.render() }
        }
        guard next != shown else { return }
        let before = shown
        shown = next
        if before?.request != next.request || before?.error != next.error || before?.typeSizes != next.typeSizes {
            build(next)
            if before != nil { onResize() }
        }
        // `.disabled(prompt.answering)`: no second answer while one is on its way.
        for button in buttons { button.isEnabled = !next.answering }
    }

    private func build(_ shown: Shown) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttons = []
        background.isHidden = shown.request == nil
        guard let request = shown.request else { return }
        let title = MacScreenText(String(format: request.scope == .full
                ? L.t("macScreen.approval.titleFull", "%@ wants to control this Mac")
                : L.t("macScreen.approval.titleView", "%@ wants to see this Mac"), request.viewerName),
            font: MacScreenType.emphasized, wraps: true)
        let glyph = MacScreenGlyph(request.scope == .full ? "cursorarrow.and.square.on.square.dashed" : "eye",
                                   font: MacScreenType.glyph, ink: \.accent)
        // SwiftUI's `Image(systemName:).font(glyph)` took the font's line height: the same header height.
        glyph.heightAnchor.constraint(equalToConstant: ceil(MacScreenType.glyph.ascender - MacScreenType.glyph.descender)).isActive = true
        let header = MacScreenStack.make(.horizontal, spacing: 10, alignment: .centerY, [glyph, title])
        MacScreenStack.addFullWidth(header, to: stack)
        stack.addArrangedSubview(MacScreenText(String(format: L.t("macScreen.approval.scope", "Asks for %@."), request.scope.title),
                                               font: MacScreenType.body, ink: \.secondary))
        if let fingerprint = request.viewerKeyFingerprint {
            let code = MacScreenText(DeviceIdentity.displayFingerprint(fingerprint), font: MacScreenType.code)
            // `.textSelection(.enabled)`: the fingerprint can be copied to compare it.
            code.isSelectable = true
            code.focusRingType = .none
            let column = MacScreenStack.make(.vertical, spacing: 2, alignment: .leading, [
                MacScreenText(L.t("macScreen.approval.fingerprint", "Device key fingerprint"), font: MacScreenType.caption, ink: \.secondary),
                code,
            ])
            stack.addArrangedSubview(column)
        }
        if let error = shown.error {
            MacScreenStack.addFullWidth(MacScreenText(error, font: MacScreenType.caption, ink: \.danger, wraps: true, width: Self.textWidth),
                                        to: stack)
        }
        let deny = answer(.deny, role: .destructive, id: "macScreen.approval.deny")
        let once = answer(.once, role: .primary, id: "macScreen.approval.once")
        MacScreenStack.addFullWidth(MacScreenStack.make(.horizontal, spacing: 8, alignment: .centerY, [deny, MacScreenSpacer(min: 8), once]),
                                    to: stack)
        stack.addArrangedSubview(MacScreenStack.make(.horizontal, spacing: 8, alignment: .centerY, [
            answer(.alwaysView, role: .plain, compact: true, id: "macScreen.approval.alwaysView"),
            answer(.alwaysFull, role: .plain, compact: true, id: "macScreen.approval.alwaysFull"),
        ]))
        title.preferredMaxLayoutWidth = Self.textWidth - 10 - glyph.intrinsicContentSize.width
        paint(stack)
    }

    private func answer(_ choice: MacScreenApprovalChoice, role: MacScreenButton.Role, compact: Bool = false, id: String) -> MacScreenButton {
        let button = MacScreenButton(choice.title, role: role, compact: compact, id: id) { [weak self] in self?.prompt.answer(choice) }
        buttons.append(button)
        return button
    }
}
