import AppKit
import CmuxNextCompat
import CmuxNextDesign
public import CmuxNextDevices
import CmuxNextWakeups
public import Observation

/// The host's approval prompt for a device hub request (permission Ask):
/// who asks and what it could do, with Allow (remembered for that Mac: the
/// hub's Always), Not Now, and under Details the device key and Allow Only
/// This Time. A floating, non-activating panel at the top right of the main
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

/// The prompt's content, in the app theme (AppKit). Leo, 2026-11-16: "super ugly", and "i dont want
/// to have to click share this mac allow every single time". So: who asks and what it can do, in
/// plain words; one primary answer, Allow, which remembers this Mac (the hub's Always, at the scope
/// asked for); a quiet Not Now; and Details, which opens below the buttons (nothing above them
/// moves) with what Allow remembers, the asking device's key, and Allow Only This Time.
/// Only a press on these buttons (a person at this Mac) answers from here.
@MainActor
final class MacScreenApprovalView: MacScreenThemedView {
    /// What the prompt shows.
    struct Shown: Equatable {
        var request: SessionRequest?
        var error: String?
        var answering: Bool
        var detailsOpen = false
        /// The type scale the prompt was built at (`MacScreenType.sizes`).
        var typeSizes = MacScreenType.sizes
    }

    static let width: CGFloat = 360
    private static let inset: CGFloat = 16
    private static let glyphColumn: CGFloat = 28
    /// The text column, right of the glyph.
    static let textWidth = width - 2 * inset - glyphColumn - 12

    /// The fitting size changed (Details, an error line).
    var onResize: @MainActor () -> Void = {}
    private let prompt: MacScreenApprovalPrompt
    private let background = MacScreenFill(\.popup, shape: .rounded(Metrics.panelCornerRadius), bordered: true)
    private let stack = MacScreenStack.make(.vertical, spacing: 12, alignment: .leading,
                                            insets: NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset))
    private var buttons: [MacScreenButton] = []
    private var detailsOpen = false
    private(set) var shown: Shown?

    init(prompt: MacScreenApprovalPrompt) {
        self.prompt = prompt
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 160))
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

    /// Opens or closes Details: it grows the panel downward, below the buttons.
    func toggleDetails() {
        detailsOpen.toggle()
        render()
    }

    private func render() {
        let next = withObservationTracking {
            Shown(request: prompt.current, error: prompt.error, answering: prompt.answering, detailsOpen: detailsOpen)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.render() }
        }
        guard next != shown else { return }
        let before = shown
        shown = next
        if before?.request != next.request || before?.error != next.error || before?.typeSizes != next.typeSizes
            || before?.detailsOpen != next.detailsOpen {
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
        let words = MacScreenApprovalWords(request)
        let glyph = MacScreenGlyph(words.symbol, font: MacScreenType.glyph, ink: \.accent, width: Self.glyphColumn)
        let title = MacScreenText(words.title, font: MacScreenType.emphasized, wraps: true, width: Self.textWidth)
        let body = MacScreenText(words.body, font: MacScreenType.body, ink: \.secondary, wraps: true, width: Self.textWidth)
        let text = MacScreenStack.make(.vertical, spacing: 3, alignment: .leading, [title, body])
        title.widthAnchor.constraint(equalToConstant: Self.textWidth).isActive = true
        body.widthAnchor.constraint(equalToConstant: Self.textWidth).isActive = true
        let header = MacScreenStack.make(.horizontal, spacing: 12, alignment: .top, [glyph, text])
        MacScreenStack.addFullWidth(header, to: stack)

        let details = MacScreenButton(MacScreenApprovalWords.details, role: .quiet, compact: true,
                                      id: "macScreen.approval.details") { [weak self] in self?.toggleDetails() }
        details.setAccessibilityExpanded(shown.detailsOpen)
        buttons.append(details)
        let notNow = answer(.deny, title: MacScreenApprovalWords.notNow, role: .plain, id: "macScreen.approval.deny")
        let allow = answer(words.allowChoice, title: MacScreenApprovalWords.allow, role: .primary, id: "macScreen.approval.allow")
        MacScreenStack.addFullWidth(MacScreenStack.make(.horizontal, spacing: 8, alignment: .centerY,
                                                        [details, MacScreenSpacer(min: 8), notNow, allow]), to: stack)

        // Below the buttons: what comes and goes never moves them.
        if let error = shown.error {
            MacScreenStack.addFullWidth(MacScreenText(error, font: MacScreenType.caption, ink: \.danger, wraps: true,
                                                      width: Self.width - 2 * Self.inset), to: stack)
        }
        if shown.detailsOpen {
            var lines: [NSView] = [MacScreenText(words.remembers, font: MacScreenType.caption, ink: \.secondary, wraps: true,
                                                 width: Self.width - 2 * Self.inset)]
            if let key = words.key {
                let code = MacScreenText(key, font: MacScreenType.code, ink: \.secondary)
                // The key can be copied to compare it with the one the asking device shows.
                code.isSelectable = true
                code.focusRingType = .none
                code.setAccessibilityIdentifier("macScreen.approval.key")
                lines.append(MacScreenStack.make(.horizontal, spacing: 6, alignment: .firstBaseline, [
                    MacScreenText(MacScreenApprovalWords.deviceKey, font: MacScreenType.caption, ink: \.tertiary), code,
                ]))
            }
            lines.append(answer(.once, title: MacScreenApprovalWords.onlyThisTime, role: .quiet, compact: true, id: "macScreen.approval.once"))
            let column = MacScreenStack.make(.vertical, spacing: 6, alignment: .leading, lines)
            MacScreenStack.addFullWidth(column, to: stack)
        }
        paint(stack)
    }

    private func answer(_ choice: MacScreenApprovalChoice, title: String, role: MacScreenButton.Role, compact: Bool = false,
                        id: String) -> MacScreenButton {
        let button = MacScreenButton(title, role: role, compact: compact, id: id) { [weak self] in self?.prompt.answer(choice) }
        buttons.append(button)
        return button
    }
}

/// The approval prompt's words for one request, plain: who asks, what it can do, and what Allow
/// keeps (the app's panel and cmux Remote's banner say the same).
nonisolated struct MacScreenApprovalWords: Equatable {
    let title: String
    let body: String
    let remembers: String
    let symbol: String
    /// Allow: the hub's Always at the scope asked for, so the next request of this Mac is not asked.
    let allowChoice: MacScreenApprovalChoice
    /// The asking device's key, grouped to compare (nil when the hub sent none).
    let key: String?

    init(_ request: SessionRequest) {
        let full = request.scope == .full
        title = String(format: full ? L.t("macScreen.approval.titleFull", "%@ wants to control this Mac")
            : L.t("macScreen.approval.titleView", "%@ wants to see this Mac"), request.viewerName)
        body = full ? L.t("macScreen.approval.bodyFull", "It can see your screen and use your mouse and keyboard.")
            : L.t("macScreen.approval.bodyView", "It can see your screen but can’t control it.")
        remembers = String(format: full
            ? L.t("macScreen.approval.remembersFull", "Allow lets %@ control this Mac from now on. Change it in Devices.")
            : L.t("macScreen.approval.remembersView", "Allow lets %@ see this Mac from now on. Change it in Devices."), request.viewerName)
        symbol = full ? "cursorarrow.and.square.on.square.dashed" : "eye"
        allowChoice = full ? .alwaysFull : .alwaysView
        key = request.viewerKeyFingerprint.map(DeviceIdentity.displayFingerprint)
    }

    static var allow: String { L.t("macScreen.approval.allow", "Allow") }
    static var notNow: String { L.t("macScreen.approval.notNow", "Not Now") }
    static var details: String { L.t("macScreen.approval.details", "Details") }
    static var deviceKey: String { L.t("macScreen.approval.deviceKey", "Device key") }
    static var onlyThisTime: String { L.t("macScreen.approval.onlyThisTime", "Allow Only This Time") }
}
