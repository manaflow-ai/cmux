import AppKit
import CmuxTerminal
import GhosttyKit

final class GhosttyPassthroughVisualEffectView: NSVisualEffectView {
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

final class TerminalLinkHoverIndicatorView: NSView {
    private enum Metrics {
        static let edgeInset: CGFloat = 12
        static let pointerGap: CGFloat = 8
        static let pointerInsetFromTopEdge: CGFloat = 24
        static let hoverHitSlop: CGFloat = 16
        static let preferredWidth: CGFloat = 420
        static let preferredHeight: CGFloat = 286
        static let minimumWidth: CGFloat = 280
        static let minimumHeight: CGFloat = 180
        static let footerHeight: CGFloat = 34
        static let cornerRadius: CGFloat = 12
    }

    private let statusBackdrop = GhosttyPassthroughVisualEffectView(frame: .zero)
    private let statusLabel = NSTextField(labelWithString: "")
    private let previewShadowView = NSView(frame: .zero)
    private let previewBackdrop = NSVisualEffectView(frame: .zero)
    private let webViewHost = NSView(frame: .zero)
    private let loadingBackdrop = NSView(frame: .zero)
    private let loadingSpinner = NSProgressIndicator(frame: .zero)
    private let footerIcon = NSImageView(frame: .zero)
    private let footerLabel = NSTextField(labelWithString: "")
    private var previewAnchor = NSPoint.zero
    private var previewTrackingArea: NSTrackingArea?
    private var pointerDownMonitor: Any?
    private var windowResignObserver: NSObjectProtocol?
    private var dismissalGeneration: UInt64 = 0
    private(set) var previewURL: URL?

    var previewWebViewHost: NSView { webViewHost }
    var isPreviewVisible: Bool { !previewShadowView.isHidden }
    var onPreviewPointerChange: ((Bool) -> Void)?
    var onPreviewPointerDown: ((Bool) -> Void)?
    var onPreviewWindowResignedKey: (() -> Void)?

    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden,
              !previewShadowView.isHidden,
              previewShadowView.frame.contains(point) else { return nil }
        // NSView suppresses its own hit testing while its presentation alpha
        // is near zero. Route through the card content so the webview is live
        // throughout both fades, including when a re-entry cancels dismissal.
        return previewBackdrop.hitTest(convert(point, to: previewBackdrop)) ?? previewShadowView
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true

        statusBackdrop.translatesAutoresizingMaskIntoConstraints = false
        statusBackdrop.material = .hudWindow
        statusBackdrop.blendingMode = .withinWindow
        statusBackdrop.state = .active
        statusBackdrop.wantsLayer = true
        statusBackdrop.layer?.cornerRadius = 6
        statusBackdrop.layer?.masksToBounds = true
        statusBackdrop.layer?.borderWidth = 1
        statusBackdrop.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        statusBackdrop.alphaValue = 0.96

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = .labelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.maximumNumberOfLines = 1
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(statusBackdrop)
        statusBackdrop.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusBackdrop.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            statusBackdrop.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            statusBackdrop.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            statusLabel.leadingAnchor.constraint(equalTo: statusBackdrop.leadingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: statusBackdrop.trailingAnchor, constant: -8),
            statusLabel.topAnchor.constraint(equalTo: statusBackdrop.topAnchor, constant: 5),
            statusLabel.bottomAnchor.constraint(equalTo: statusBackdrop.bottomAnchor, constant: -5),
        ])

        configurePreviewCard()
        installPointerDownMonitor()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    deinit {
        if let pointerDownMonitor {
            NSEvent.removeMonitor(pointerDownMonitor)
        }
        if let windowResignObserver {
            NotificationCenter.default.removeObserver(windowResignObserver)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowResignObserver {
            NotificationCenter.default.removeObserver(windowResignObserver)
            self.windowResignObserver = nil
        }
        guard let window else { return }
        windowResignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard self?.isPreviewVisible == true else { return }
                self?.onPreviewWindowResignedKey?()
            }
        }
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard event.trackingArea === previewTrackingArea else { return }
        onPreviewPointerChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard event.trackingArea === previewTrackingArea else { return }
        onPreviewPointerChange?(false)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard event.trackingArea === previewTrackingArea else { return }
        onPreviewPointerChange?(true)
    }

    override func layout() {
        super.layout()
        guard previewURL != nil else { return }
        layoutPreviewCard(at: previewAnchor)
    }

    func setURL(_ url: String?) {
        let url = url?.isEmpty == false ? url : nil
        statusLabel.stringValue = url ?? ""
        statusLabel.setAccessibilityLabel(url)
        statusBackdrop.isHidden = url == nil || isPreviewVisible
        isHidden = url == nil && !isPreviewVisible
    }

    @discardableResult
    func preparePreview(url: URL, at anchor: NSPoint) -> Bool {
        guard availablePreviewSize() != nil else { return false }
        dismissalGeneration &+= 1
        previewURL = url
        previewAnchor = anchor
        footerLabel.stringValue = url.absoluteString
        footerLabel.setAccessibilityLabel(url.absoluteString)
        footerIcon.image = NSImage(
            systemSymbolName: url.scheme?.lowercased() == "https" ? "lock.fill" : "network",
            accessibilityDescription: nil
        )
        layoutPreviewCard(at: anchor)
        isHidden = false
        statusBackdrop.isHidden = true
        previewShadowView.layer?.removeAllAnimations()
        previewShadowView.alphaValue = 0
        previewShadowView.isHidden = false
        setPreviewLoadState(.loading)
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            previewShadowView.alphaValue = 1
            return true
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            previewShadowView.animator().alphaValue = 1
        }
        return true
    }

    func cancelPreviewDismissal() {
        guard previewURL != nil, !previewShadowView.isHidden else { return }
        dismissalGeneration &+= 1
        previewShadowView.layer?.removeAllAnimations()
        previewShadowView.alphaValue = 1
        statusBackdrop.isHidden = true
        isHidden = false
    }

    func setPreviewLoadState(_ state: BrowserPrewarmedWebViewPool.LoadState) {
        let isLoading = state == .loading
        loadingBackdrop.isHidden = !isLoading
        if isLoading {
            loadingSpinner.startAnimation(nil)
        } else {
            loadingSpinner.stopAnimation(nil)
        }
    }

    func dismissPreview(animated: Bool = true, completion: (() -> Void)? = nil) {
        dismissalGeneration &+= 1
        let scheduledGeneration = dismissalGeneration
        loadingSpinner.stopAnimation(nil)
        guard !previewShadowView.isHidden else {
            finishPreviewDismissal(generation: scheduledGeneration, completion: completion)
            return
        }
        previewShadowView.layer?.removeAllAnimations()
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            finishPreviewDismissal(generation: scheduledGeneration, completion: completion)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            previewShadowView.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.finishPreviewDismissal(
                generation: scheduledGeneration,
                completion: completion
            )
        }
    }

    var previewOwnsFirstResponder: Bool {
        guard let responderView = window?.firstResponder as? NSView else { return false }
        return responderView === previewShadowView || responderView.isDescendant(of: previewShadowView)
    }

    func resignPreviewFirstResponderIfNeeded() {
        guard previewOwnsFirstResponder else { return }
        window?.makeFirstResponder(nil)
    }

    private func configurePreviewCard() {
        previewShadowView.wantsLayer = true
        previewShadowView.layer?.shadowColor = NSColor.black.cgColor
        previewShadowView.layer?.shadowOpacity = 0.34
        previewShadowView.layer?.shadowRadius = 18
        previewShadowView.layer?.shadowOffset = NSSize(width: 0, height: -5)
        previewShadowView.isHidden = true
        previewShadowView.alphaValue = 0
        previewShadowView.setAccessibilityIdentifier("TerminalLinkPreviewCard")

        previewBackdrop.material = .popover
        previewBackdrop.blendingMode = .withinWindow
        previewBackdrop.state = .active
        previewBackdrop.wantsLayer = true
        previewBackdrop.layer?.cornerRadius = Metrics.cornerRadius
        previewBackdrop.layer?.cornerCurve = .continuous
        previewBackdrop.layer?.masksToBounds = true
        previewBackdrop.layer?.borderWidth = 1
        previewBackdrop.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor

        webViewHost.wantsLayer = true
        webViewHost.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        webViewHost.setAccessibilityIdentifier("TerminalLinkPreviewWebViewHost")

        loadingBackdrop.wantsLayer = true
        loadingBackdrop.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.82).cgColor

        loadingSpinner.style = .spinning
        loadingSpinner.controlSize = .small
        loadingSpinner.isIndeterminate = true

        footerIcon.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)
        footerIcon.contentTintColor = .secondaryLabelColor
        footerIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)

        footerLabel.font = .systemFont(ofSize: 11, weight: .medium)
        footerLabel.textColor = .secondaryLabelColor
        footerLabel.lineBreakMode = .byTruncatingMiddle
        footerLabel.maximumNumberOfLines = 1

        addSubview(previewShadowView)
        previewShadowView.addSubview(previewBackdrop)
        previewBackdrop.addSubview(webViewHost)
        previewBackdrop.addSubview(footerIcon)
        previewBackdrop.addSubview(footerLabel)
        previewBackdrop.addSubview(loadingBackdrop)
        loadingBackdrop.addSubview(loadingSpinner)
    }

    private func installPointerDownMonitor() {
        pointerDownMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self, self.isPreviewVisible else { return event }
            let isInsidePreview: Bool
            if event.window === self.window {
                let point = self.convert(event.locationInWindow, from: nil)
                isInsidePreview = self.previewShadowView.frame.contains(point)
            } else {
                isInsidePreview = false
            }
            self.onPreviewPointerDown?(isInsidePreview)
            return event
        }
    }

    private func finishPreviewDismissal(
        generation scheduledGeneration: UInt64,
        completion: (() -> Void)?
    ) {
        guard dismissalGeneration == scheduledGeneration else { return }
        previewURL = nil
        previewShadowView.layer?.removeAllAnimations()
        previewShadowView.alphaValue = 0
        previewShadowView.isHidden = true
        removePreviewTrackingArea()
        statusBackdrop.isHidden = statusLabel.stringValue.isEmpty
        isHidden = statusLabel.stringValue.isEmpty
        completion?()
    }

    private func availablePreviewSize() -> NSSize? {
        let width = min(Metrics.preferredWidth, bounds.width - Metrics.edgeInset * 2)
        let height = min(Metrics.preferredHeight, bounds.height - Metrics.edgeInset * 2)
        guard width >= Metrics.minimumWidth, height >= Metrics.minimumHeight else { return nil }
        return NSSize(width: width, height: height)
    }

    private func layoutPreviewCard(at anchor: NSPoint) {
        guard let size = availablePreviewSize() else {
            dismissPreview(animated: false)
            return
        }

        let usableBounds = bounds.insetBy(dx: Metrics.edgeInset, dy: Metrics.edgeInset)
        var x = anchor.x + Metrics.pointerGap
        if x + size.width > usableBounds.maxX {
            x = anchor.x - Metrics.pointerGap - size.width
        }
        x = min(max(x, usableBounds.minX), usableBounds.maxX - size.width)

        var y = anchor.y - size.height + Metrics.pointerInsetFromTopEdge
        y = min(max(y, usableBounds.minY), usableBounds.maxY - size.height)

        previewShadowView.frame = NSRect(origin: NSPoint(x: x, y: y), size: size)
        previewShadowView.layer?.shadowPath = CGPath(
            roundedRect: previewShadowView.bounds,
            cornerWidth: Metrics.cornerRadius,
            cornerHeight: Metrics.cornerRadius,
            transform: nil
        )
        previewBackdrop.frame = previewShadowView.bounds
        webViewHost.frame = NSRect(
            x: 0,
            y: Metrics.footerHeight,
            width: size.width,
            height: size.height - Metrics.footerHeight
        )
        loadingBackdrop.frame = webViewHost.frame
        loadingSpinner.sizeToFit()
        loadingSpinner.frame.origin = NSPoint(
            x: loadingBackdrop.bounds.midX - loadingSpinner.frame.width / 2,
            y: loadingBackdrop.bounds.midY - loadingSpinner.frame.height / 2
        )
        footerIcon.frame = NSRect(x: 12, y: 10, width: 12, height: 12)
        footerLabel.frame = NSRect(
            x: 30,
            y: 8,
            width: max(0, size.width - 42),
            height: 17
        )
        updatePreviewTrackingArea()
    }

    private func updatePreviewTrackingArea() {
        // The card is closer to the pointer than this halo is wide, and its
        // vertical edge straddles the pointer. The expanded rect therefore
        // forms one continuous, menu-like hover bridge into the live webview.
        // hitTest still accepts only the visible card, so the bridge does not
        // consume terminal selection or clicks.
        let trackingRect = previewShadowView.frame
            .insetBy(dx: -Metrics.hoverHitSlop, dy: -Metrics.hoverHitSlop)
            .intersection(bounds)
        guard !trackingRect.isNull, !trackingRect.isEmpty else {
            removePreviewTrackingArea()
            return
        }
        guard previewTrackingArea?.rect != trackingRect else { return }

        removePreviewTrackingArea()
        let trackingArea = NSTrackingArea(
            rect: trackingRect,
            options: [
                .mouseEnteredAndExited,
                .mouseMoved,
                .activeInKeyWindow,
                .enabledDuringMouseDrag,
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        previewTrackingArea = trackingArea
    }

    private func removePreviewTrackingArea() {
        guard let previewTrackingArea else { return }
        removeTrackingArea(previewTrackingArea)
        self.previewTrackingArea = nil
    }
}

extension GhosttySurfaceScrollView {
    nonisolated static func linkHoverURL(from link: ghostty_action_mouse_over_link_s) -> String? {
        guard link.len > 0, let bytes = link.url else { return nil }
        return String(data: Data(bytes: bytes, count: Int(link.len)), encoding: .utf8)
    }

    func setLinkHoverURL(_ url: String?) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.setLinkHoverURL(url) }
            return
        }
        let anchor: NSPoint
        if let trackedAnchor = surfaceView.terminalLinkPreviewAnchor(in: linkHoverIndicatorView) {
            anchor = trackedAnchor
        } else if let window {
            anchor = linkHoverIndicatorView.convert(
                window.mouseLocationOutsideOfEventStream,
                from: nil
            )
        } else {
            anchor = NSPoint(x: linkHoverIndicatorView.bounds.midX, y: linkHoverIndicatorView.bounds.midY)
        }
        let terminalSurface = surfaceView.terminalSurface
        terminalLinkPreviewController?.update(
            rawURL: url,
            sourceWorkspaceId: terminalSurface?.tabId,
            sourcePanelId: terminalSurface?.id,
            anchorPoint: anchor
        )
    }
}

func shouldAllowEnsureFocusWindowActivation(
    activeTabManager: TabManager?,
    targetTabManager: TabManager,
    keyWindow: NSWindow?,
    mainWindow: NSWindow?,
    targetWindow: NSWindow
) -> Bool {
    guard activeTabManager === targetTabManager || (keyWindow == nil && mainWindow == nil) else {
        return false
    }

    if let keyWindow {
        return keyWindow === targetWindow
    }

    if let mainWindow {
        return mainWindow === targetWindow
    }

    return true
}

extension TerminalSurface {
    func debugInitialCommand() -> String? {
        initialCommand
    }

    func debugTmuxStartCommand() -> String? {
        tmuxStartCommand
    }

    func debugInitialInputMetadata() -> (hasInitialInput: Bool, byteCount: Int) {
        let byteCount = initialInput?.utf8.count ?? 0
        return (byteCount > 0, byteCount)
    }

    func debugInitialInputForTesting() -> String? {
        initialInput
    }
}
