import AppKit
import ObjectiveC
import QuartzCore

@MainActor
private final class BrowserScreenshotFlashView: NSView, CAAnimationDelegate {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.36).cgColor
        layer?.opacity = 0
        layer?.zPosition = 20_000
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isOpaque: Bool { false }

    func play() {
        guard let layer else {
            removeFromSuperview()
            return
        }

        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0.32
        animation.toValue = 0
        animation.duration = 0.20
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        animation.delegate = self
        layer.add(animation, forKey: "browserScreenshotFlash")
    }

    nonisolated func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        Task { @MainActor [weak self] in
            self?.removeFromSuperview()
        }
    }
}

@MainActor
private enum BrowserScreenshotFlash {
    static func show(over view: NSView) {
        view.subviews
            .compactMap { $0 as? BrowserScreenshotFlashView }
            .forEach { $0.removeFromSuperview() }

        let flash = BrowserScreenshotFlashView(frame: view.bounds)
        view.addSubview(flash, positioned: .above, relativeTo: nil)
        flash.play()
    }
}

@MainActor
private final class BrowserScreenshotSelectionOverlayView: NSView {
    private let onFinish: (NSRect?) -> Void
    private let instructionBadgeView = FileDropHintBadgeView(frame: .zero)
    private var dragStart: NSPoint?
    private var dragCurrent: NSPoint?
    private var dashPhase: CGFloat = 0
    private var dashTimer: Timer?
    private var didFinish = false

    init(frame: NSRect, onFinish: @escaping (NSRect?) -> Void) {
        self.onFinish = onFinish
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        layer?.zPosition = 10_000
        addSubview(instructionBadgeView)
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        dashTimer?.invalidate()
    }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            window?.makeFirstResponder(self)
            startDashAnimation()
            updateInstructionBadge()
        } else {
            dashTimer?.invalidate()
            dashTimer = nil
        }
    }

    override func layout() {
        super.layout()
        updateInstructionBadge()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        instructionBadgeView.hide()
        let point = clampedPoint(convert(event.locationInWindow, from: nil))
        dragStart = point
        dragCurrent = point
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragStart != nil else { return }
        dragCurrent = clampedPoint(convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil else {
            cancel()
            return
        }
        dragCurrent = clampedPoint(convert(event.locationInWindow, from: nil))
        guard let selection = selectionRect, selection.width >= 2, selection.height >= 2 else {
            cancel()
            return
        }
        finish(selection)
    }

    override func rightMouseDown(with event: NSEvent) {
        _ = event
        cancel()
    }

    override func keyDown(with event: NSEvent) {
        if Self.isCancelEvent(event) {
            cancel()
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if Self.isCancelEvent(event) {
            cancel()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        _ = dirtyRect
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        context.saveGState()
        NSColor.black.withAlphaComponent(0.42).setFill()
        if let selection = selectionRect, selection.width > 0, selection.height > 0 {
            let dimPath = NSBezierPath(rect: bounds)
            dimPath.append(NSBezierPath(rect: selection))
            dimPath.windingRule = .evenOdd
            dimPath.fill()
            drawSelectionBorder(selection)
            drawDimensionsTooltip(for: selection)
        } else {
            bounds.fill()
        }
        context.restoreGState()
    }

    private var selectionRect: NSRect? {
        guard let dragStart, let dragCurrent else { return nil }
        return NSRect(
            x: min(dragStart.x, dragCurrent.x),
            y: min(dragStart.y, dragCurrent.y),
            width: abs(dragCurrent.x - dragStart.x),
            height: abs(dragCurrent.y - dragStart.y)
        )
    }

    private static func isCancelEvent(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 {
            return true
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return modifiers.contains(.command) && event.charactersIgnoringModifiers == "."
    }

    private func clampedPoint(_ point: NSPoint) -> NSPoint {
        NSPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    private func startDashAnimation() {
        guard dashTimer == nil else { return }
        dashTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                dashPhase = (dashPhase + 1).truncatingRemainder(dividingBy: 8)
                needsDisplay = true
            }
        }
    }

    private func drawSelectionBorder(_ selection: NSRect) {
        let border = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1

        NSColor.white.setStroke()
        var whitePattern: [CGFloat] = [4, 4]
        border.setLineDash(&whitePattern, count: whitePattern.count, phase: dashPhase)
        border.stroke()

        NSColor.black.setStroke()
        var blackPattern: [CGFloat] = [4, 4]
        border.setLineDash(&blackPattern, count: blackPattern.count, phase: dashPhase + 4)
        border.stroke()
    }

    private func drawDimensionsTooltip(for selection: NSRect) {
        let text = "\(Int(selection.width)) x \(Int(selection.height))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let textSize = attributed.size()
        let padding = NSSize(width: 8, height: 4)
        let tooltipSize = NSSize(width: textSize.width + padding.width * 2, height: textSize.height + padding.height * 2)
        let origin = tooltipOrigin(for: tooltipSize, near: selection)
        let backgroundRect = NSRect(origin: origin, size: tooltipSize)

        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: backgroundRect, xRadius: 4, yRadius: 4).fill()
        attributed.draw(
            at: NSPoint(
                x: backgroundRect.minX + padding.width,
                y: backgroundRect.minY + padding.height
            )
        )
    }

    private func updateInstructionBadge() {
        guard dragStart == nil, window != nil, bounds.width > 0, bounds.height > 0 else {
            instructionBadgeView.hide()
            return
        }
        instructionBadgeView.show(
            text: String(
                localized: "browser.screenshotSection.instructions",
                defaultValue: "Click and drag to select. Esc cancels."
            ),
            centeredIn: bounds,
            clippedTo: bounds
        )
    }

    private func tooltipOrigin(for tooltipSize: NSSize, near selection: NSRect) -> NSPoint {
        let preferred = NSPoint(
            x: selection.minX,
            y: selection.minY - tooltipSize.height - 8
        )
        if bounds.contains(NSRect(origin: preferred, size: tooltipSize)) {
            return preferred
        }

        let fallbackY = min(bounds.maxY - tooltipSize.height - 8, selection.maxY + 8)
        return NSPoint(
            x: min(max(bounds.minX + 8, selection.minX), bounds.maxX - tooltipSize.width - 8),
            y: max(bounds.minY + 8, fallbackY)
        )
    }

    private func cancel() {
        finish(nil)
    }

    private func finish(_ selection: NSRect?) {
        guard !didFinish else { return }
        didFinish = true
        dashTimer?.invalidate()
        dashTimer = nil
        removeFromSuperview()
        onFinish(selection)
    }
}

private var cmuxWebViewScreenshotCaptureGateKey: UInt8 = 0
private var cmuxWebViewScreenshotSelectionOverlayKey: UInt8 = 0

extension CmuxWebView {
    @MainActor
    private var screenshotCaptureGate: BrowserScreenshotCaptureGate {
        if let gate = objc_getAssociatedObject(self, &cmuxWebViewScreenshotCaptureGateKey) as? BrowserScreenshotCaptureGate {
            return gate
        }

        let gate = BrowserScreenshotCaptureGate()
        objc_setAssociatedObject(
            self,
            &cmuxWebViewScreenshotCaptureGateKey,
            gate,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        return gate
    }

    private var screenshotSelectionOverlay: BrowserScreenshotSelectionOverlayView? {
        get {
            objc_getAssociatedObject(self, &cmuxWebViewScreenshotSelectionOverlayKey) as? BrowserScreenshotSelectionOverlayView
        }
        set {
            objc_setAssociatedObject(
                self,
                &cmuxWebViewScreenshotSelectionOverlayKey,
                newValue,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }

    func appendScreenshotContextMenuItems(to menu: NSMenu) {
        let pageTitle = String(localized: "browser.contextMenu.screenshotPage", defaultValue: "Screenshot Page")
        let sectionTitle = String(localized: "browser.contextMenu.screenshotSection", defaultValue: "Screenshot Section")
        let items: [(title: String, action: Selector, symbolName: String)] = [
            (pageTitle, #selector(contextMenuScreenshotPage(_:)), "camera"),
            (sectionTitle, #selector(contextMenuScreenshotSection(_:)), "viewfinder"),
        ].filter { item in
            !menu.items.contains { $0.action == item.action || $0.title == item.title }
        }

        guard !items.isEmpty else {
            return
        }

        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }
        for (title, action, symbolName) in items {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
            menu.addItem(item)
        }
    }

    @MainActor
    func captureScreenshotPageToClipboard() async -> Bool {
        do {
            guard let _ = try await screenshotCaptureGate.run({
                try await BrowserScreenshotPipeline.captureAndWrite(
                    mode: .fullPage,
                    snapshot: { try await BrowserScreenshotWebViewSnapshotter.captureFullPage(from: self) },
                    pasteboard: .general
                )
            }) else {
                #if DEBUG
                cmuxDebugLog("browser.screenshot.page.ignored reason=captureInProgress")
                #endif
                return false
            }
            BrowserScreenshotFlash.show(over: self)
            return true
        } catch {
            #if DEBUG
            cmuxDebugLog("browser.screenshot.page.failed error=\(error.localizedDescription)")
            #endif
            NSSound.beep()
            return false
        }
    }

    @objc func contextMenuScreenshotPage(_ sender: Any?) {
        _ = sender
        Task { @MainActor [weak self] in
            _ = await self?.captureScreenshotPageToClipboard()
        }
    }

    @objc func contextMenuScreenshotSection(_ sender: Any?) {
        _ = sender
        beginScreenshotSectionSelection()
    }

    private func beginScreenshotSectionSelection() {
        screenshotSelectionOverlay?.removeFromSuperview()

        let overlay = BrowserScreenshotSelectionOverlayView(frame: bounds) { [weak self] selection in
            guard let self else { return }
            self.screenshotSelectionOverlay = nil
            guard let selection else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    guard let _ = try await self.screenshotCaptureGate.run({
                        try await BrowserScreenshotPipeline.captureAndWrite(
                            mode: .section(selectionInView: selection, viewBounds: self.bounds),
                            snapshot: { try await BrowserScreenshotWebViewSnapshotter.captureVisibleViewport(from: self) },
                            pasteboard: .general
                        )
                    }) else {
                        #if DEBUG
                        cmuxDebugLog("browser.screenshot.section.ignored reason=captureInProgress")
                        #endif
                        return
                    }
                    BrowserScreenshotFlash.show(over: self)
                } catch {
                    #if DEBUG
                    cmuxDebugLog("browser.screenshot.section.failed error=\(error.localizedDescription)")
                    #endif
                    NSSound.beep()
                }
            }
        }
        screenshotSelectionOverlay = overlay
        addSubview(overlay, positioned: .above, relativeTo: nil)
        window?.makeFirstResponder(overlay)
    }
}

extension BrowserPanel {
    @MainActor
    func captureScreenshotPageToClipboard() async -> Bool {
        guard let webView = webView as? CmuxWebView else {
            NSSound.beep()
            return false
        }
        return await webView.captureScreenshotPageToClipboard()
    }
}
