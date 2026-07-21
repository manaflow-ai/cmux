import AppKit
import CmuxAppKitSupportUI
import CmuxWorkspaces
import SwiftUI

// MARK: - SwiftUI popover presenter

/// Presents existing SwiftUI popover content (`SidebarWorkspaceStatusPopover`,
/// `SidebarWorkspaceChecklistPopover`) from a pure-AppKit row cell. Popovers
/// sit off the scroll path, so hosting SwiftUI here reuses the legacy views
/// wholesale for exact parity instead of reimplementing them in AppKit.
///
/// Follows `SidebarWorkspaceTodoPopoverHost`'s contract:
/// - No `sizingOptions` on the hosting controller; `contentSize` is driven
///   manually from `fittingSize` (clamped to `minWidth`/`maxHeight`).
/// - Each hidden-to-shown transition bumps the SwiftUI view identity so every
///   open gets fresh view-local state.
/// - The popover window is promoted to key on show so embedded fields and
///   keyboard navigation receive input (`PopoverKeyWindowElevator`).
@MainActor
final class SidebarRowSwiftUIPopoverPresenter: NSObject, NSPopoverDelegate {
    var minWidth: CGFloat = 200
    var maxHeight: CGFloat = 480
    /// Called when AppKit closed the popover out from under the container
    /// (transient click-away, app deactivation) — NOT for programmatic
    /// `close()` calls. Containers use this to write presentation state back.
    var onExternalDismiss: (() -> Void)?

    /// Lazy: cells allocate presenters eagerly, but the hosting machinery
    /// only spins up when a popover actually presents (off the scroll path).
    private lazy var hostingController = NSHostingController(rootView: AnyView(EmptyView()))
    private var popover: NSPopover?
    private var presentationCount = 0
    private var closingProgrammatically = false
    /// Visible refreshes arrive from the table's configure pass (inside a
    /// representable update turn); defer + coalesce them like
    /// `SidebarWorkspaceTodoPopoverHost` does instead of forcing synchronous
    /// hosted-view layout per publisher burst.
    private let visibleUpdateScheduler = CmuxPopoverVisibleUpdateScheduler()
    private var pendingRoot: AnyView?

    var isShown: Bool { popover?.isShown == true }

    func present(
        _ root: AnyView,
        relativeTo rect: NSRect,
        of view: NSView,
        preferredEdge: NSRectEdge
    ) {
        guard view.window != nil else { return }
        let popover = self.popover ?? makePopover()
        guard !popover.isShown else {
            update(root)
            return
        }
        visibleUpdateScheduler.cancel()
        pendingRoot = nil
        presentationCount += 1
        applyRootView(root)
        popover.show(relativeTo: rect, of: view, preferredEdge: preferredEdge)
    }

    /// Live refresh while shown: mutations reach the row through the normal
    /// configure pass, which forwards the fresh content here so open popovers
    /// repaint instead of showing creation-time state. Deferred + coalesced
    /// outside the current update turn.
    func update(_ root: AnyView) {
        guard isShown else { return }
        pendingRoot = root
        visibleUpdateScheduler.schedule { [weak self] in
            guard let self, self.isShown, let root = self.pendingRoot else { return }
            self.pendingRoot = nil
            self.applyRootView(root)
        }
    }

    func close() {
        visibleUpdateScheduler.cancel()
        pendingRoot = nil
        guard let popover, popover.isShown else { return }
        closingProgrammatically = true
        popover.performClose(nil)
    }

    private func applyRootView(_ root: AnyView) {
        hostingController.rootView = AnyView(root.id(presentationCount))
        hostingController.view.invalidateIntrinsicContentSize()
        hostingController.view.layoutSubtreeIfNeeded()
        updateContentSize()
    }

    private func makePopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = hostingController
        popover.delegate = self
        self.popover = popover
        return popover
    }

    private func updateContentSize() {
        let fitting = hostingController.view.fittingSize
        guard fitting.width > 0, fitting.height > 0, let popover else { return }
        CmuxPopoverMutation.setContentSize(NSSize(
            width: ceil(max(fitting.width, minWidth)),
            height: ceil(min(fitting.height, maxHeight))
        ), on: popover)
    }

    func popoverDidShow(_ notification: Notification) {
        PopoverKeyWindowElevator.promoteToKeyIfPossible(hostingController.view.window)
    }

    func popoverDidClose(_ notification: Notification) {
        visibleUpdateScheduler.cancel()
        pendingRoot = nil
        popover = nil
        // Release the hosted content: the root view's action closures capture
        // the presented workspace strongly, and this presenter lives on a
        // pooled table cell — keeping the last root would retain a closed
        // workspace across cell reuse.
        hostingController.rootView = AnyView(EmptyView())
        let external = !closingProgrammatically
        closingProgrammatically = false
        if external {
            onExternalDismiss?()
        }
        onExternalDismiss = nil
    }
}

// MARK: - Closure menu item

/// NSMenuItem driven by a closure (the lanes menu has no long-lived target).
@MainActor
final class SidebarRowClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(execute), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func execute() {
        handler()
    }
}

// MARK: - Manual status glyph

/// Pure-AppKit port of `SidebarWorkspaceTaskStatusGlyph` for the row's title
/// line: circle outline + progress pie + Done checkmark, drawn with the exact
/// SwiftUI geometry (9pt base circle in an 11pt slot, both font-scaled,
/// 1pt stroke / 1.4pt for attention, checkmark stroke 1.2 round). The control
/// frame adds the legacy button's 2pt padding on every edge.
@MainActor
final class SidebarRowTaskStatusGlyphButton: NSControl {
    struct Model: Equatable {
        let status: WorkspaceTaskStatus
        let hasOverride: Bool
        let usesMonochrome: Bool
        let fontScale: CGFloat
    }

    private static let baseSize: CGFloat = 9
    private static let slotWidth: CGFloat = 11
    private static let strokeWidth: CGFloat = 1
    private static let attentionStrokeWidth: CGFloat = 1.4
    private static let padding: CGFloat = 2

    var onClick: (() -> Void)?
    private var model: Model?
    private var monochromeColor: NSColor = .secondaryLabelColor
    private var neutralColor: NSColor = .secondaryLabelColor

    override var isFlipped: Bool { true }

    func configure(model: Model, monochromeColor: NSColor, neutralColor: NSColor) {
        let changed = self.model != model
            || self.monochromeColor != monochromeColor
            || self.neutralColor != neutralColor
        self.model = model
        self.monochromeColor = monochromeColor
        self.neutralColor = neutralColor
        toolTip = SidebarWorkspaceTaskStatusGlyphModel.tooltip(
            status: model.status,
            hasOverride: model.hasOverride
        )
        setAccessibilityRole(.button)
        setAccessibilityLabel(String(
            localized: "sidebar.status.compactLabel",
            defaultValue: "Status: \(model.status.displayName)"
        ))
        setAccessibilityIdentifier("SidebarWorkspaceManualStatusIndicatorMenu")
        if changed {
            needsDisplay = true
        }
    }

    /// The control's occupied size: the fixed-width slot plus 2pt padding
    /// (legacy: `.frame(width: slotWidth * fontScale)` + `.padding(2)`).
    static func occupiedSize(fontScale: CGFloat) -> NSSize {
        NSSize(
            width: slotWidth * fontScale + padding * 2,
            height: baseSize * fontScale + padding * 2
        )
    }

    private var statusColor: NSColor {
        guard let model else { return neutralColor }
        if model.usesMonochrome { return monochromeColor }
        switch SidebarWorkspaceTaskStatusGlyphModel(status: model.status).colorRole {
        case .neutral:
            return neutralColor
        case .working:
            return cmuxAccentNSColor()
        case .attention:
            // Loudest lane: full-strength attention accent between orange and red.
            return NSColor(srgbRed: 1.0, green: 0.42, blue: 0.2, alpha: 1)
        case .review:
            return .systemGreen
        case .done:
            // Muted gray-green so finished rows read as settled, not celebratory.
            return NSColor(srgbRed: 0.45, green: 0.62, blue: 0.5, alpha: 1)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let model, let context = NSGraphicsContext.current?.cgContext else { return }
        let glyph = SidebarWorkspaceTaskStatusGlyphModel(status: model.status)
        let size = Self.baseSize * model.fontScale
        let circleRect = CGRect(
            x: (bounds.width - size) / 2,
            y: (bounds.height - size) / 2,
            width: size,
            height: size
        )
        let color = statusColor.cgColor
        let strokeWidth = glyph.colorRole == .attention ? Self.attentionStrokeWidth : Self.strokeWidth

        context.setStrokeColor(color)
        context.setLineWidth(strokeWidth)
        context.strokeEllipse(in: circleRect)

        if glyph.fillFraction >= 1 {
            context.setFillColor(color)
            context.fillEllipse(in: circleRect)
        } else if glyph.fillFraction > 0 {
            // Same math as `SidebarStatusPieShape` (the view is flipped, so
            // SwiftUI's y-down arc renders identically): 12 o'clock sweeping
            // clockwise by `fillFraction` of the circle.
            let center = CGPoint(x: circleRect.midX, y: circleRect.midY)
            let radius = min(circleRect.width, circleRect.height) / 2
            let path = CGMutablePath()
            path.move(to: center)
            path.addArc(
                center: center,
                radius: radius,
                startAngle: -.pi / 2,
                endAngle: -.pi / 2 + 2 * .pi * max(0, min(glyph.fillFraction, 1)),
                clockwise: false
            )
            path.closeSubpath()
            context.addPath(path)
            context.setFillColor(color)
            context.fillPath()
        }

        if glyph.showsCheckmark {
            // `SidebarStatusCheckmarkShape` point fractions in the circle rect.
            let checkmark = CGMutablePath()
            checkmark.move(to: CGPoint(
                x: circleRect.minX + circleRect.width * 0.28,
                y: circleRect.minY + circleRect.height * 0.52
            ))
            checkmark.addLine(to: CGPoint(
                x: circleRect.minX + circleRect.width * 0.45,
                y: circleRect.minY + circleRect.height * 0.68
            ))
            checkmark.addLine(to: CGPoint(
                x: circleRect.minX + circleRect.width * 0.74,
                y: circleRect.minY + circleRect.height * 0.34
            ))
            context.addPath(checkmark)
            context.setStrokeColor(
                (model.usesMonochrome ? NSColor.black.withAlphaComponent(0.7) : .white).cgColor
            )
            context.setLineWidth(1.2)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.strokePath()
        }
    }

    override func mouseDown(with event: NSEvent) {
        // Swallow so the table row action does not also fire (legacy: the
        // glyph Button consumes the click without selecting the row), and
        // dim while pressed like a SwiftUI plain Button.
        alphaValue = SidebarRowPressedDim.pressedAlpha
    }

    override func mouseUp(with event: NSEvent) {
        alphaValue = 1
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        onClick?()
    }

    /// VoiceOver/keyboard activation parity with the legacy SwiftUI Button.
    override func accessibilityPerformPress() -> Bool {
        guard let onClick else { return false }
        onClick()
        return true
    }
}

/// The SwiftUI plain-button pressed treatment the legacy checklist/status
/// Buttons had: content dims to half strength while the mouse is down.
enum SidebarRowPressedDim {
    static let pressedAlpha: CGFloat = 0.5
}

// MARK: - Compact status line (hidesAllDetails mode)

/// Pure-AppKit port of the legacy `compactWorkspaceStatusMenu` row: a flag
/// glyph plus "Status: X" that opens the status-lane menu on press. Shown
/// only in compact detail mode (`hidesAllDetails`) for workspaces with a
/// visible status.
@MainActor
final class SidebarRowCompactStatusLine: NSControl {
    private let iconView = NSImageView()
    private let label = SidebarRowTextView(lines: 1)

    var menuProvider: (() -> NSMenu)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        status: WorkspaceTaskStatus,
        model: SidebarWorkspaceRowModel,
        palette: SidebarRowPalette
    ) {
        iconView.image = RenderableSystemSymbol.configuredAppKitImage(
            systemName: "flag", pointSize: model.scaled(8), weight: nil
        )
        iconView.contentTintColor = palette.secondary(0.65)
        label.stringValue = String(
            localized: "sidebar.status.compactLabel",
            defaultValue: "Status: \(status.displayName)"
        )
        label.font = .systemFont(ofSize: model.scaled(10), weight: .semibold)
        label.textColor = palette.secondary(0.9)
        toolTip = String(localized: "sidebar.status.compactTooltip", defaultValue: "Change workspace status")
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("SidebarWorkspaceCompactStatusMenu")
        needsLayout = true
    }

    func measuredHeight(width: CGFloat) -> CGFloat {
        let iconSide = iconView.image?.size.height ?? 0
        return max(iconSide, label.sidebarNaturalCellSize.height)
    }

    override func layout() {
        super.layout()
        let iconSize = iconView.image?.size ?? .zero
        iconView.frame = NSRect(
            x: 0,
            y: (bounds.height - iconSize.height) / 2,
            width: iconSize.width,
            height: iconSize.height
        )
        let labelSize = label.sidebarNaturalCellSize
        let labelX = iconSize.width > 0 ? iconSize.width + 4 : 0
        label.frame = NSRect(
            x: labelX,
            y: (bounds.height - labelSize.height) / 2,
            width: max(10, bounds.width - labelX),
            height: labelSize.height
        )
    }

    override func mouseDown(with event: NSEvent) {
        // Legacy SwiftUI `Menu` opens on press, not on release; dim while
        // the menu tracks (popUp blocks until dismissal).
        presentLanesMenu()
    }

    /// VoiceOver/keyboard activation parity with the legacy SwiftUI Menu.
    override func accessibilityPerformPress() -> Bool {
        guard menuProvider != nil else { return false }
        presentLanesMenu()
        return true
    }

    private func presentLanesMenu() {
        guard let menu = menuProvider?() else { return }
        alphaValue = SidebarRowPressedDim.pressedAlpha
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 2), in: self)
        alphaValue = 1
    }
}
