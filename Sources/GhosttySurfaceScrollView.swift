import Foundation
import CmuxTerminalCopyMode
import CmuxSocketControl
import SwiftUI
import AppKit
import Metal
import QuartzCore
import Combine
import CoreText
import Darwin
import Carbon.HIToolbox
import os
import Sentry
import Bonsplit
import CMUXAgentLaunch
import CMUXMobileCore
import CMUXPasteboardFidelity
import IOSurface
import UniformTypeIdentifiers

extension NSScreen {
    var displayID: UInt32? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let v = deviceDescription[key] as? UInt32 { return v }
        if let v = deviceDescription[key] as? Int { return UInt32(v) }
        if let v = deviceDescription[key] as? NSNumber { return v.uint32Value }
        return nil
    }
}

struct GhosttyScrollbar {
    let total: UInt64
    let offset: UInt64
    let len: UInt64

    init(c: ghostty_action_scrollbar_s) {
        total = c.total
        offset = c.offset
        len = c.len
    }
}

extension Notification.Name {
    static let ghosttyDidTick = Notification.Name("ghosttyDidTick")
    static let ghosttyDidRenderFrame = Notification.Name("ghosttyDidRenderFrame")
    static let terminalSurfaceDidCompleteClipboardRead = Notification.Name("terminalSurfaceDidCompleteClipboardRead")
    static let ghosttyDidUpdateScrollbar = Notification.Name("ghosttyDidUpdateScrollbar")
    static let ghosttyDidUpdateCellSize = Notification.Name("ghosttyDidUpdateCellSize")
    static let ghosttyDidReceiveWheelScroll = Notification.Name("ghosttyDidReceiveWheelScroll")
    static let ghosttySearchFocus = Notification.Name("ghosttySearchFocus")
    static let ghosttyConfigDidReload = Notification.Name("ghosttyConfigDidReload")
    static let ghosttyDefaultBackgroundDidChange = Notification.Name("ghosttyDefaultBackgroundDidChange")
    static let browserSearchFocus = Notification.Name("browserSearchFocus")
}

// MARK: - Scroll View Wrapper (Ghostty-style scrollbar)

private final class GhosttyScrollView: NSScrollView {
    weak var surfaceView: GhosttyNSView?

    // Keep keyboard routing on the terminal surface; this wrapper is viewport plumbing.
    override var acceptsFirstResponder: Bool { false }

    override func scrollWheel(with event: NSEvent) {
        guard let surfaceView else {
            super.scrollWheel(with: event)
            return
        }

        // Route wheel gestures to the terminal surface so Ghostty handles scrollback.
        // Letting NSScrollView consume these events moves the wrapper viewport itself,
        // which causes pane-content drift instead of terminal scrollback movement.
        GhosttyNSView.focusLog("GhosttyScrollView.scrollWheel: surface scroll")
        if window?.firstResponder !== surfaceView {
            window?.makeFirstResponder(surfaceView)
        }
        surfaceView.scrollWheel(with: event)
    }
}

final class GhosttyFlashOverlayView: NSView {
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private final class TerminalViewportBorderOverlayView: NSView {
    var effectiveSize: CGSize? {
        didSet { needsDisplay = true }
    }

    var drawsVisibleAreaBorder = false {
        didSet { needsDisplay = true }
    }
    var drawsVisibleAreaRightBorder = false {
        didSet { needsDisplay = true }
    }
    var drawsVisibleAreaBottomBorder = false {
        didSet { needsDisplay = true }
    }

    override var acceptsFirstResponder: Bool { false }
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard drawsVisibleAreaBorder,
              let effectiveSize,
              effectiveSize.width > 1,
              effectiveSize.height > 1 else {
            return
        }

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let lineWidth = 1 / max(1, scale)
        let width = min(effectiveSize.width, bounds.width)
        let height = min(effectiveSize.height, bounds.height)
        guard width > lineWidth, height > lineWidth else { return }

        let path = NSBezierPath()
        path.lineWidth = lineWidth
        let x = width - lineWidth / 2
        let y = height - lineWidth / 2
        if drawsVisibleAreaRightBorder {
            path.move(to: NSPoint(x: x, y: 0))
            path.line(to: NSPoint(x: x, y: y))
        }
        if drawsVisibleAreaBottomBorder {
            path.move(to: NSPoint(x: 0, y: y))
            path.line(to: NSPoint(x: x, y: y))
        }
        // Stroke the exact window-chrome separator color used by the pane outline,
        // sidebar trailing edge, and tab-bar separators (one source of truth), so the
        // iOS-connected viewport border is pixel-identical to every other border in the
        // app instead of the previous hardcoded near-white separator stroke.
        WindowChromeSeparatorColor.current().setStroke()
        path.stroke()
    }
}

final class GhosttySurfaceScrollView: NSView {
    enum FlashStyle {
        case navigation
        case notification
    }

    static func flashStyle(for reason: WorkspaceAttentionFlashReason) -> FlashStyle {
        switch reason {
        case .navigation:
            return .navigation
        case .notificationArrival, .notificationDismiss, .unreadIndicatorDismiss, .debug:
            return .notification
        }
    }

    private static func flashPresentation(for style: FlashStyle) -> WorkspaceAttentionFlashPresentation {
        switch style {
        case .navigation:
            return WorkspaceAttentionCoordinator.flashStyle(for: .navigation)
        case .notification:
            return WorkspaceAttentionCoordinator.flashStyle(for: .notificationArrival)
        }
    }

    private enum NotificationRingMetrics {
        static let inset = PanelOverlayRingMetrics.inset
        static let cornerRadius = PanelOverlayRingMetrics.cornerRadius
        static let lineWidth = PanelOverlayRingMetrics.lineWidth
    }

    private var sharedBackdropCutoutView: NSView?
    private let backgroundView: NSView
    private let scrollView: GhosttyScrollView
    private let documentView: NSView
    private let surfaceView: GhosttyNSView
    private let mobileViewportBorderOverlayView = TerminalViewportBorderOverlayView(frame: .zero)
    private let inactiveOverlayView: GhosttyFlashOverlayView
    private let dropZoneOverlayView: GhosttyFlashOverlayView
    private let paneDropTargetView = TerminalPaneDropTargetView(frame: .zero)
    private let notificationRingOverlayView: GhosttyFlashOverlayView
    private let notificationRingLayer: CAShapeLayer
    private let flashOverlayView: GhosttyFlashOverlayView
    private let flashLayer: CAShapeLayer
    var isRightSidebarDockSurface: Bool {
        surfaceView.terminalSurface?.focusPlacement == .rightSidebarDock
    }

    var uiWindow: NSWindow? {
        if let terminalSurface = surfaceView.terminalSurface {
            return terminalSurface.uiWindow
        }
        return window
    }

    func forwardKeyDownToSurface(_ event: NSEvent) {
        surfaceView.keyDown(with: event)
    }

    private var lastFlashStyle: FlashStyle = .navigation
    private let keyboardCopyModeBadgeContainerView: GhosttyFlashOverlayView
    private let keyboardCopyModeBadgeView: GhosttyPassthroughVisualEffectView
    private let keyboardCopyModeBadgeIconView: NSImageView
    private let keyboardCopyModeBadgeLabel: NSTextField
    private let imageTransferIndicatorContainerView: NSView
    private let imageTransferIndicatorView: NSVisualEffectView
    private let imageTransferIndicatorSpinner: NSProgressIndicator
    private let imageTransferCancelButton: NSButton
    private var searchOverlayHostingView: NSHostingView<SurfaceSearchOverlay>?
    private var deferredSearchOverlayMutationWorkItem: DispatchWorkItem?
    private var imageTransferIndicatorShowWorkItem: DispatchWorkItem?
    private var activeImageTransferOperation: TerminalImageTransferOperation?
    private var activeImageTransferCancelHandler: (() -> Void)?
    private var lastSearchOverlayStateID: ObjectIdentifier?
    private var searchOverlayMutationGeneration: UInt64 = 0
    private var observers: [NSObjectProtocol] = []
    private var windowObservers: [NSObjectProtocol] = []
    private var scrollbarTrackingArea: NSTrackingArea?
    private var isLiveScrolling = false
    private var lastSentRow: Int?
    /// Tracks whether the user has scrolled away from the bottom to review scrollback.
    /// When true, auto-scroll should be suspended to prevent the "doomscroll" bug
    /// where the terminal fights the user's scroll position.
    private var userScrolledAwayFromBottom = false
    private var pendingExplicitWheelScroll = false
    private var allowExplicitScrollbarSync = false
    /// Threshold in points from bottom to consider "at bottom" (allows for minor float drift)
    private static let scrollToBottomThreshold: CGFloat = 5.0
    private var isActive = true
    private var lastFocusRefreshAt: CFTimeInterval = 0
    private var lastRequestedPortalOcclusionVisible: Bool?
    private var activeDropZone: DropZone?
    private var pendingDropZone: DropZone?
    private var dropZoneOverlayAnimationGeneration: UInt64 = 0
    private var pendingAutomaticFirstResponderApply = false
    // Intentionally no focus retry loops: rely on AppKit first-responder and bonsplit selection.

    /// Tracks whether keyboard focus should go to the search field or the terminal
    /// when the window becomes key while the find bar is open.
    enum SearchFocusTarget {
        case searchField
        case terminal
    }
    private(set) var searchFocusTarget: SearchFocusTarget = .searchField


#if DEBUG
    private var lastDropZoneOverlayLogSignature: String?
    private var lastDragGeometryLogSignature: String?
    private var dragLayoutLogSequence: UInt64 = 0
    private static let tabTransferPasteboardType = NSPasteboard.PasteboardType("com.splittabbar.tabtransfer")
    private static let sidebarTabReorderPasteboardType = NSPasteboard.PasteboardType("com.cmux.sidebar-tab-reorder")
    private static var flashCounts: [UUID: Int] = [:]
    private static var drawCounts: [UUID: Int] = [:]
    private static var lastDrawTimes: [UUID: CFTimeInterval] = [:]
    private static var presentCounts: [UUID: Int] = [:]
    private static var dropOverlayShowCounts: [UUID: Int] = [:]
    private static var lastPresentTimes: [UUID: CFTimeInterval] = [:]
    private static var lastContentsKeys: [UUID: String] = [:]

    static func flashCount(for surfaceId: UUID) -> Int {
        flashCounts[surfaceId, default: 0]
    }

    static func resetFlashCounts() {
        flashCounts.removeAll()
    }

    private static func recordFlash(for surfaceId: UUID) {
        flashCounts[surfaceId, default: 0] += 1
    }

    static func drawStats(for surfaceId: UUID) -> (count: Int, last: CFTimeInterval) {
        (drawCounts[surfaceId, default: 0], lastDrawTimes[surfaceId, default: 0])
    }

    static func resetDrawStats() {
        drawCounts.removeAll()
        lastDrawTimes.removeAll()
    }

    static func recordSurfaceDraw(_ surfaceId: UUID) {
        drawCounts[surfaceId, default: 0] += 1
        lastDrawTimes[surfaceId] = CACurrentMediaTime()
    }

    private static func contentsKey(for layer: CALayer?) -> String {
        guard let modelLayer = layer else { return "nil" }
        // Prefer the presentation layer to better reflect what the user sees on screen.
        let layer = modelLayer.presentation() ?? modelLayer
        guard let contents = layer.contents else { return "nil" }
        // Prefer pointer identity for object/CFType contents.
        if let obj = contents as AnyObject? {
            let ptr = Unmanaged.passUnretained(obj).toOpaque()
            var key = "0x" + String(UInt(bitPattern: ptr), radix: 16)

            // For IOSurface-backed terminal layers, the IOSurface object can remain stable while
            // its contents change. Include the IOSurface seed so "new frame rendered" is visible
            // to debug/test tooling even when the pointer identity doesn't change.
            let cf = contents as CFTypeRef
            if CFGetTypeID(cf) == IOSurfaceGetTypeID() {
                let surfaceRef = (contents as! IOSurfaceRef)
                let seed = IOSurfaceGetSeed(surfaceRef)
                key += ":seed=\(seed)"
            }

            return key
        }
        return String(describing: contents)
    }

    private static func updatePresentStats(surfaceId: UUID, layer: CALayer?) -> (count: Int, last: CFTimeInterval, key: String) {
        let key = contentsKey(for: layer)
        if lastContentsKeys[surfaceId] != key {
            presentCounts[surfaceId, default: 0] += 1
            lastPresentTimes[surfaceId] = CACurrentMediaTime()
            lastContentsKeys[surfaceId] = key
        }
        return (presentCounts[surfaceId, default: 0], lastPresentTimes[surfaceId, default: 0], key)
    }

    private func recordDropOverlayShowAnimation() {
        guard let surfaceId = surfaceView.terminalSurface?.id else { return }
        Self.dropOverlayShowCounts[surfaceId, default: 0] += 1
    }

    func debugProbeDropOverlayAnimation(useDeferredPath: Bool) -> (before: Int, after: Int, bounds: CGSize) {
        guard let surfaceId = surfaceView.terminalSurface?.id else {
            return (0, 0, bounds.size)
        }

        let before = Self.dropOverlayShowCounts[surfaceId, default: 0]

        // Reset to a hidden baseline so each probe exercises an initial-show transition.
        dropZoneOverlayAnimationGeneration &+= 1
        activeDropZone = nil
        pendingDropZone = nil
        dropZoneOverlayView.layer?.removeAllAnimations()
        dropZoneOverlayView.isHidden = true
        dropZoneOverlayView.alphaValue = 1

        if useDeferredPath {
            pendingDropZone = .left
            synchronizeGeometryAndContent()
        } else {
            setDropZoneOverlay(zone: .left)
        }

        let after = Self.dropOverlayShowCounts[surfaceId, default: 0]
        setDropZoneOverlay(zone: nil)
        return (before, after, bounds.size)
    }

    var debugSurfaceId: UUID? {
        surfaceView.terminalSurface?.id
    }

    var debugCellSize: CGSize {
        surfaceView.cellSize
    }

    private func debugPointInSurface(_ point: NSPoint) -> NSPoint {
        surfaceView.convert(point, from: self)
    }

    func debugSimulateSelection(from startPoint: NSPoint, to endPoint: NSPoint) -> Bool {
        surfaceView.debugSimulateSelection(
            from: debugPointInSurface(startPoint),
            to: debugPointInSurface(endPoint)
        )
    }

    func debugSimulateCommandHover(at point: NSPoint) -> Bool {
        surfaceView.debugSimulateCommandHover(at: debugPointInSurface(point))
    }

    func debugSimulateCommandHoverDetails(at point: NSPoint) -> [String: Any] {
        surfaceView.debugSimulateCommandHoverDetails(at: debugPointInSurface(point))
    }

    func debugSimulateCommandClick(at point: NSPoint) -> [String: Any] {
        surfaceView.debugSimulateCommandClick(at: debugPointInSurface(point))
    }
#endif

    func portalBindingGuardState() -> (surfaceId: UUID?, generation: UInt64?, state: String) {
        guard let terminalSurface = surfaceView.terminalSurface else {
            return (surfaceId: nil, generation: nil, state: "missingSurface")
        }
        return (
            surfaceId: terminalSurface.id,
            generation: terminalSurface.portalBindingGeneration(),
            state: terminalSurface.portalBindingStateLabel()
        )
    }

    func canAcceptPortalBinding(expectedSurfaceId: UUID?, expectedGeneration: UInt64?) -> Bool {
        guard let terminalSurface = surfaceView.terminalSurface else { return false }
        return terminalSurface.canAcceptPortalBinding(
            expectedSurfaceId: expectedSurfaceId,
            expectedGeneration: expectedGeneration
        )
    }

    func releaseOwnedPortalHost(hostId: ObjectIdentifier, reason: String) {
        surfaceView.terminalSurface?.releasePortalHostIfOwned(
            hostId: hostId,
            reason: reason
        )
    }

    func prepareOwnedPortalHostForTransientReattach(hostId: ObjectIdentifier, reason: String) {
        surfaceView.terminalSurface?.preparePortalHostReplacementIfOwned(
            hostId: hostId,
            reason: reason
        )
    }

    init(surfaceView: GhosttyNSView) {
        #if DEBUG
        dispatchPrecondition(condition: .onQueue(.main))
        #endif

        self.surfaceView = surfaceView
        backgroundView = NSView(frame: .zero)
        scrollView = GhosttyScrollView()
        inactiveOverlayView = GhosttyFlashOverlayView(frame: .zero)
        dropZoneOverlayView = GhosttyFlashOverlayView(frame: .zero)
        notificationRingOverlayView = GhosttyFlashOverlayView(frame: .zero)
        notificationRingLayer = CAShapeLayer()
        flashOverlayView = GhosttyFlashOverlayView(frame: .zero)
        flashLayer = CAShapeLayer()
        keyboardCopyModeBadgeContainerView = GhosttyFlashOverlayView(frame: .zero)
        keyboardCopyModeBadgeView = GhosttyPassthroughVisualEffectView(frame: .zero)
        keyboardCopyModeBadgeIconView = NSImageView(frame: .zero)
        keyboardCopyModeBadgeLabel = NSTextField(labelWithString: terminalKeyboardCopyModeIndicatorText)
        imageTransferIndicatorContainerView = NSView(frame: .zero)
        imageTransferIndicatorView = NSVisualEffectView(frame: .zero)
        imageTransferIndicatorSpinner = NSProgressIndicator(frame: .zero)
        imageTransferCancelButton = NSButton(frame: .zero)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.usesPredominantAxisScrolling = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.contentView.clipsToBounds = true
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.backgroundColor = .clear
        scrollView.surfaceView = surfaceView

        documentView = NSView(frame: .zero)
        scrollView.documentView = documentView
        documentView.addSubview(surfaceView)

        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true

        backgroundView.wantsLayer = true
        backgroundView.layer?.backgroundColor = NSColor.clear.cgColor
        backgroundView.layer?.isOpaque = false
        addSubview(backgroundView)
        addSubview(scrollView)
        mobileViewportBorderOverlayView.isHidden = true
        addSubview(mobileViewportBorderOverlayView, positioned: .above, relativeTo: scrollView)
        paneDropTargetView.hostedView = self
        addSubview(paneDropTargetView, positioned: .above, relativeTo: nil)
        synchronizeScrollbarAppearance()
        inactiveOverlayView.wantsLayer = true
        inactiveOverlayView.layer?.backgroundColor = NSColor.clear.cgColor
        inactiveOverlayView.isHidden = true
        addSubview(inactiveOverlayView)
        dropZoneOverlayView.wantsLayer = true
        dropZoneOverlayView.layer?.backgroundColor = cmuxAccentNSColor().withAlphaComponent(0.25).cgColor
        dropZoneOverlayView.layer?.borderColor = cmuxAccentNSColor().cgColor
        dropZoneOverlayView.layer?.borderWidth = 2
        dropZoneOverlayView.layer?.cornerRadius = 8
        dropZoneOverlayView.isHidden = true
        notificationRingOverlayView.wantsLayer = true
        notificationRingOverlayView.layer?.backgroundColor = NSColor.clear.cgColor
        notificationRingOverlayView.layer?.masksToBounds = false
        notificationRingOverlayView.autoresizingMask = [.width, .height]
        let notificationRingStyle = WorkspaceAttentionCoordinator.notificationRingStyle
        let notificationRingColor = notificationRingStyle.accent.strokeColor
        notificationRingLayer.fillColor = NSColor.clear.cgColor
        notificationRingLayer.strokeColor = notificationRingColor.cgColor
        notificationRingLayer.lineWidth = NotificationRingMetrics.lineWidth
        notificationRingLayer.lineJoin = .round
        notificationRingLayer.lineCap = .round
        notificationRingLayer.shadowColor = notificationRingColor.cgColor
        notificationRingLayer.shadowOpacity = Float(notificationRingStyle.glowOpacity)
        notificationRingLayer.shadowRadius = notificationRingStyle.glowRadius
        notificationRingLayer.shadowOffset = .zero
        notificationRingLayer.opacity = 0
        notificationRingOverlayView.layer?.addSublayer(notificationRingLayer)
        notificationRingOverlayView.isHidden = true
        addSubview(notificationRingOverlayView)
        flashOverlayView.wantsLayer = true
        flashOverlayView.layer?.backgroundColor = NSColor.clear.cgColor
        flashOverlayView.layer?.masksToBounds = false
        flashOverlayView.autoresizingMask = [.width, .height]
        let flashStyle = WorkspaceAttentionCoordinator.flashStyle(for: .navigation)
        let flashColor = flashStyle.accent.strokeColor
        flashLayer.fillColor = NSColor.clear.cgColor
        flashLayer.strokeColor = flashColor.cgColor
        flashLayer.lineWidth = NotificationRingMetrics.lineWidth
        flashLayer.lineJoin = .round
        flashLayer.lineCap = .round
        flashLayer.shadowColor = flashColor.cgColor
        flashLayer.shadowOpacity = Float(flashStyle.glowOpacity)
        flashLayer.shadowRadius = flashStyle.glowRadius
        flashLayer.shadowOffset = .zero
        flashLayer.opacity = 0
        flashOverlayView.layer?.addSublayer(flashLayer)
        addSubview(flashOverlayView)
        keyboardCopyModeBadgeContainerView.translatesAutoresizingMaskIntoConstraints = false
        keyboardCopyModeBadgeContainerView.wantsLayer = true
        keyboardCopyModeBadgeContainerView.layer?.masksToBounds = false
        keyboardCopyModeBadgeContainerView.layer?.shadowColor = NSColor.black.cgColor
        keyboardCopyModeBadgeContainerView.layer?.shadowOpacity = 0.22
        keyboardCopyModeBadgeContainerView.layer?.shadowRadius = 10
        keyboardCopyModeBadgeContainerView.layer?.shadowOffset = CGSize(width: 0, height: 2)
        keyboardCopyModeBadgeView.translatesAutoresizingMaskIntoConstraints = false
        keyboardCopyModeBadgeView.wantsLayer = true
        keyboardCopyModeBadgeView.material = .hudWindow
        keyboardCopyModeBadgeView.blendingMode = .withinWindow
        keyboardCopyModeBadgeView.state = .active
        keyboardCopyModeBadgeView.layer?.cornerRadius = 18
        keyboardCopyModeBadgeView.layer?.masksToBounds = true
        keyboardCopyModeBadgeView.layer?.borderWidth = 1
        keyboardCopyModeBadgeView.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        keyboardCopyModeBadgeView.alphaValue = 0.97
        keyboardCopyModeBadgeIconView.translatesAutoresizingMaskIntoConstraints = false
        keyboardCopyModeBadgeIconView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 13,
            weight: .regular,
            scale: .medium
        )
        keyboardCopyModeBadgeIconView.image = NSImage(
            systemSymbolName: "keyboard.badge.ellipsis",
            accessibilityDescription: terminalKeyTableIndicatorAccessibilityLabel
        )
        keyboardCopyModeBadgeIconView.contentTintColor = NSColor.secondaryLabelColor
        keyboardCopyModeBadgeLabel.translatesAutoresizingMaskIntoConstraints = false
        keyboardCopyModeBadgeLabel.textColor = NSColor.labelColor
        keyboardCopyModeBadgeLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        keyboardCopyModeBadgeLabel.lineBreakMode = .byTruncatingTail
        keyboardCopyModeBadgeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        keyboardCopyModeBadgeLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        keyboardCopyModeBadgeContainerView.addSubview(keyboardCopyModeBadgeView)
        keyboardCopyModeBadgeView.addSubview(keyboardCopyModeBadgeIconView)
        keyboardCopyModeBadgeView.addSubview(keyboardCopyModeBadgeLabel)
        NSLayoutConstraint.activate([
            keyboardCopyModeBadgeView.topAnchor.constraint(equalTo: keyboardCopyModeBadgeContainerView.topAnchor),
            keyboardCopyModeBadgeView.bottomAnchor.constraint(equalTo: keyboardCopyModeBadgeContainerView.bottomAnchor),
            keyboardCopyModeBadgeView.leadingAnchor.constraint(equalTo: keyboardCopyModeBadgeContainerView.leadingAnchor),
            keyboardCopyModeBadgeView.trailingAnchor.constraint(equalTo: keyboardCopyModeBadgeContainerView.trailingAnchor),
            keyboardCopyModeBadgeView.widthAnchor.constraint(lessThanOrEqualToConstant: 180),
            keyboardCopyModeBadgeIconView.leadingAnchor.constraint(equalTo: keyboardCopyModeBadgeView.leadingAnchor, constant: 12),
            keyboardCopyModeBadgeIconView.centerYAnchor.constraint(equalTo: keyboardCopyModeBadgeView.centerYAnchor),
            keyboardCopyModeBadgeIconView.widthAnchor.constraint(equalToConstant: 18),
            keyboardCopyModeBadgeIconView.heightAnchor.constraint(equalToConstant: 18),
            keyboardCopyModeBadgeLabel.leadingAnchor.constraint(equalTo: keyboardCopyModeBadgeIconView.trailingAnchor, constant: 7),
            keyboardCopyModeBadgeLabel.trailingAnchor.constraint(equalTo: keyboardCopyModeBadgeView.trailingAnchor, constant: -14),
            keyboardCopyModeBadgeLabel.topAnchor.constraint(equalTo: keyboardCopyModeBadgeView.topAnchor, constant: 8),
            keyboardCopyModeBadgeLabel.bottomAnchor.constraint(equalTo: keyboardCopyModeBadgeView.bottomAnchor, constant: -8),
        ])
        keyboardCopyModeBadgeContainerView.isHidden = true
        addSubview(keyboardCopyModeBadgeContainerView)
        NSLayoutConstraint.activate([
            keyboardCopyModeBadgeContainerView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            keyboardCopyModeBadgeContainerView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])

        imageTransferIndicatorContainerView.translatesAutoresizingMaskIntoConstraints = false
        imageTransferIndicatorContainerView.wantsLayer = true
        imageTransferIndicatorContainerView.layer?.masksToBounds = false
        imageTransferIndicatorContainerView.layer?.shadowColor = NSColor.black.cgColor
        imageTransferIndicatorContainerView.layer?.shadowOpacity = 0.18
        imageTransferIndicatorContainerView.layer?.shadowRadius = 8
        imageTransferIndicatorContainerView.layer?.shadowOffset = CGSize(width: 0, height: 2)
        imageTransferIndicatorView.translatesAutoresizingMaskIntoConstraints = false
        imageTransferIndicatorView.wantsLayer = true
        imageTransferIndicatorView.material = .hudWindow
        imageTransferIndicatorView.blendingMode = .withinWindow
        imageTransferIndicatorView.state = .active
        imageTransferIndicatorView.layer?.cornerRadius = 16
        imageTransferIndicatorView.layer?.masksToBounds = true
        imageTransferIndicatorView.layer?.borderWidth = 1
        imageTransferIndicatorView.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        imageTransferIndicatorView.alphaValue = 0.95
        imageTransferIndicatorSpinner.translatesAutoresizingMaskIntoConstraints = false
        imageTransferIndicatorSpinner.style = .spinning
        imageTransferIndicatorSpinner.controlSize = .small
        imageTransferIndicatorSpinner.isDisplayedWhenStopped = false
        imageTransferCancelButton.translatesAutoresizingMaskIntoConstraints = false
        imageTransferCancelButton.isBordered = false
        imageTransferCancelButton.imagePosition = .imageOnly
        imageTransferCancelButton.image = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: String(localized: "common.cancel", defaultValue: "Cancel")
        )
        imageTransferCancelButton.contentTintColor = NSColor.secondaryLabelColor
        imageTransferCancelButton.toolTip = String(localized: "common.cancel", defaultValue: "Cancel")
        imageTransferCancelButton.setAccessibilityLabel(
            String(localized: "common.cancel", defaultValue: "Cancel")
        )
        imageTransferCancelButton.target = self
        imageTransferCancelButton.action = #selector(handleImageTransferCancel)
        imageTransferIndicatorContainerView.addSubview(imageTransferIndicatorView)
        imageTransferIndicatorView.addSubview(imageTransferIndicatorSpinner)
        imageTransferIndicatorView.addSubview(imageTransferCancelButton)
        NSLayoutConstraint.activate([
            imageTransferIndicatorView.topAnchor.constraint(equalTo: imageTransferIndicatorContainerView.topAnchor),
            imageTransferIndicatorView.bottomAnchor.constraint(equalTo: imageTransferIndicatorContainerView.bottomAnchor),
            imageTransferIndicatorView.leadingAnchor.constraint(equalTo: imageTransferIndicatorContainerView.leadingAnchor),
            imageTransferIndicatorView.trailingAnchor.constraint(equalTo: imageTransferIndicatorContainerView.trailingAnchor),
            imageTransferIndicatorSpinner.leadingAnchor.constraint(equalTo: imageTransferIndicatorView.leadingAnchor, constant: 10),
            imageTransferIndicatorSpinner.centerYAnchor.constraint(equalTo: imageTransferIndicatorView.centerYAnchor),
            imageTransferIndicatorSpinner.widthAnchor.constraint(equalToConstant: 14),
            imageTransferIndicatorSpinner.heightAnchor.constraint(equalToConstant: 14),
            imageTransferCancelButton.leadingAnchor.constraint(equalTo: imageTransferIndicatorSpinner.trailingAnchor, constant: 6),
            imageTransferCancelButton.trailingAnchor.constraint(equalTo: imageTransferIndicatorView.trailingAnchor, constant: -8),
            imageTransferCancelButton.centerYAnchor.constraint(equalTo: imageTransferIndicatorView.centerYAnchor),
            imageTransferCancelButton.widthAnchor.constraint(equalToConstant: 16),
            imageTransferCancelButton.heightAnchor.constraint(equalToConstant: 16),
            imageTransferIndicatorSpinner.topAnchor.constraint(equalTo: imageTransferIndicatorView.topAnchor, constant: 8),
            imageTransferIndicatorSpinner.bottomAnchor.constraint(equalTo: imageTransferIndicatorView.bottomAnchor, constant: -8),
        ])
        imageTransferIndicatorContainerView.isHidden = true
        addSubview(imageTransferIndicatorContainerView)
        NSLayoutConstraint.activate([
            imageTransferIndicatorContainerView.topAnchor.constraint(
                equalTo: keyboardCopyModeBadgeContainerView.bottomAnchor,
                constant: 8
            ),
            imageTransferIndicatorContainerView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])

        scrollView.contentView.postsBoundsChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.handleScrollChange()
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            self?.isLiveScrolling = true
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            self?.isLiveScrolling = false
            // Final scroll position check to update userScrolledAwayFromBottom state
            self?.handleLiveScroll()
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.didLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            self?.handleLiveScroll()
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidUpdateScrollbar,
            object: surfaceView,
            queue: .main
        ) { [weak self] notification in
            self?.handleScrollbarUpdate(notification)
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidBecomeReady,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let readySurfaceId = notification.userInfo?["surfaceId"] as? UUID,
                  readySurfaceId == self.surfaceView.terminalSurface?.id else {
                return
            }
            // Session restore can request focus before the runtime surface exists.
            // Re-run the normal first-responder/focus path once the surface is live.
            guard self.isActive || self.surfaceView.desiredFocus || self.isSurfaceViewFirstResponder() else {
                return
            }
            self.scheduleAutomaticFirstResponderApply(reason: "surfaceDidBecomeReady")
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidReceiveWheelScroll,
            object: surfaceView,
            queue: .main
        ) { [weak self] _ in
            self?.pendingExplicitWheelScroll = true
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttySearchFocus,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let surface = notification.object as? TerminalSurface,
                  surface === self.surfaceView.terminalSurface else { return }
            self.searchFocusTarget = .searchField
            // Explicitly unfocus the terminal so the cursor stops blinking
            // when the search field takes over.
            surface.setFocus(false)
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidUpdateCellSize,
            object: surfaceView,
            queue: .main
        ) { [weak self] _ in
            self?.synchronizeScrollView()
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: NSScroller.preferredScrollerStyleDidChangeNotification,
            object: nil,
            // Match AppKit's geometry change immediately so the terminal width
            // does not stay stuck behind a legacy scrollbar gutter.
            queue: nil
        ) { [weak self] _ in
            self?.handlePreferredScrollerStyleChange()
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: TerminalScrollBarSettings.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleTerminalScrollBarPreferenceChange()
        })

    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    deinit {
#if DEBUG
        cmuxDebugLog(
            "surface.hosted.deinit surface=\(debugSurfaceId?.uuidString.prefix(5) ?? "nil") " +
            "inWindow=\(window != nil ? 1 : 0) hasSuperview=\(superview != nil ? 1 : 0) " +
            "hidden=\(isHidden ? 1 : 0) frame=\(String(format: "%.1fx%.1f", frame.width, frame.height))"
        )
#endif
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        deferredSearchOverlayMutationWorkItem?.cancel()
        imageTransferIndicatorShowWorkItem?.cancel()
        dropZoneOverlayView.removeFromSuperview()
        cancelFocusRequest()
    }

    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }

    // Avoid stealing focus on scroll; focus is managed explicitly by the surface view.
    override var acceptsFirstResponder: Bool { false }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard scrollView.hasVerticalScroller,
              NSScroller.preferredScrollerStyle == .legacy else { return }
        scrollView.flashScrollers()
    }

    override func updateTrackingAreas() {
        if let scrollbarTrackingArea {
            removeTrackingArea(scrollbarTrackingArea)
            self.scrollbarTrackingArea = nil
        }

        super.updateTrackingAreas()

        guard scrollView.hasVerticalScroller,
              let scroller = scrollView.verticalScroller else { return }

        let trackingArea = NSTrackingArea(
            rect: convert(scroller.bounds, from: scroller),
            options: [
                .mouseMoved,
                .activeInKeyWindow,
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        scrollbarTrackingArea = trackingArea
    }

    override func layout() {
        super.layout()
        synchronizeGeometryAndContent()
        _ = setFrameIfNeeded(paneDropTargetView, to: bounds)
        bringPaneDropTargetToFrontIfNeeded()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard activeDropZone != nil || pendingDropZone != nil else { return }
        attachDropZoneOverlayIfNeeded()
        if let zone = activeDropZone ?? pendingDropZone {
            applyDropZoneOverlayFrame(dropZoneOverlayFrame(for: zone, in: bounds.size))
        }
    }

    /// Reconcile AppKit geometry with ghostty surface geometry synchronously.
    /// Used after split topology mutations (close/split) to prevent a stale one-frame
    /// IOSurface size from being presented after pane expansion.
    @discardableResult
    func reconcileGeometryNow() -> Bool {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.reconcileGeometryNow()
            }
            return false
        }

        return synchronizeGeometryAndContent()
    }

    /// Request an immediate terminal redraw after geometry updates so stale IOSurface
    /// contents do not remain stretched during live resize churn.
    func refreshSurfaceNow(reason: String = "portal.refreshSurfaceNow") {
        // Portal reparent/reveal can settle geometry a tick before AppKit finishes
        // realizing the terminal subtree's backing layer state. Flush display for the
        // hosted subtree first so forceRefresh does not race a still-unrealized layer.
        layoutSubtreeIfNeeded()
        surfaceView.layoutSubtreeIfNeeded()
        displayIfNeeded()
        surfaceView.displayIfNeeded()
        surfaceView.terminalSurface?.forceRefresh(reason: reason)
    }

    @discardableResult
    private func synchronizeGeometryAndContent() -> Bool {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let didScrollbarAppearanceChange = synchronizeScrollbarAppearance()
        let previousSurfaceSize = surfaceView.frame.size
        if let sharedBackdropCutoutView {
            _ = setFrameIfNeeded(sharedBackdropCutoutView, to: bounds)
        }
        _ = setFrameIfNeeded(backgroundView, to: bounds)
        _ = setFrameIfNeeded(scrollView, to: bounds)
        let targetSize = scrollView.bounds.size
#if DEBUG
        logLayoutDuringActiveDrag(targetSize: targetSize)
#endif
        let targetSurfaceFrame = CGRect(origin: surfaceView.frame.origin, size: targetSize)
        _ = setFrameIfNeeded(surfaceView, to: targetSurfaceFrame)
        let targetDocumentFrame = CGRect(
            origin: documentView.frame.origin,
            size: CGSize(width: scrollView.bounds.width, height: documentView.frame.height)
        )
        _ = setFrameIfNeeded(documentView, to: targetDocumentFrame)
        _ = setFrameIfNeeded(mobileViewportBorderOverlayView, to: bounds)
        _ = setFrameIfNeeded(inactiveOverlayView, to: bounds)
        _ = setFrameIfNeeded(paneDropTargetView, to: bounds)
        if let zone = activeDropZone {
            attachDropZoneOverlayIfNeeded()
            _ = setFrameIfNeeded(
                dropZoneOverlayView,
                to: dropZoneOverlayFrame(for: zone, in: bounds.size)
            )
        }
        if let pending = pendingDropZone,
           bounds.width > 2,
           bounds.height > 2 {
            pendingDropZone = nil
#if DEBUG
            let frame = dropZoneOverlayFrame(for: pending, in: bounds.size)
            logDropZoneOverlay(event: "flushPending", zone: pending, frame: frame)
#endif
            // Reuse the normal show/update path so deferred overlays get the
            // same initial animation as direct drop-zone activation.
            setDropZoneOverlay(zone: pending)
        }
        _ = setFrameIfNeeded(notificationRingOverlayView, to: bounds)
        _ = setFrameIfNeeded(flashOverlayView, to: bounds)
        if let overlay = searchOverlayHostingView {
            _ = setFrameIfNeeded(overlay, to: bounds)
        }
        bringPaneDropTargetToFrontIfNeeded()
        // NSScrollView can defer clip-view/content-size updates until its own layout pass,
        // which makes interactive width changes arrive a queue turn late on Sequoia.
        if didScrollbarAppearanceChange {
            scrollView.tile()
        }
        scrollView.layoutSubtreeIfNeeded()
        updateNotificationRingPath()
        updateFlashPath(style: lastFlashStyle)
        updateFlashAppearance(style: lastFlashStyle)
        synchronizeScrollView()
        synchronizeSurfaceView()
        let didCoreSurfaceChange = synchronizeCoreSurface()
        return !sizeApproximatelyEqual(previousSurfaceSize, targetSize) || didCoreSurfaceChange
    }

    func setMobileViewportBorder(size: CGSize?, drawRight: Bool, drawBottom: Bool) {
        let isVisible = drawRight || drawBottom
        mobileViewportBorderOverlayView.effectiveSize = size
        mobileViewportBorderOverlayView.drawsVisibleAreaBorder = isVisible
        mobileViewportBorderOverlayView.drawsVisibleAreaRightBorder = drawRight
        mobileViewportBorderOverlayView.drawsVisibleAreaBottomBorder = drawBottom
        mobileViewportBorderOverlayView.isHidden = !isVisible
    }

    @discardableResult
    private func setFrameIfNeeded(_ view: NSView, to frame: CGRect) -> Bool {
        guard !Self.rectApproximatelyEqual(view.frame, frame) else { return false }
        view.frame = frame
        return true
    }

    private func sizeApproximatelyEqual(_ lhs: CGSize, _ rhs: CGSize, epsilon: CGFloat = 0.0001) -> Bool {
        abs(lhs.width - rhs.width) <= epsilon && abs(lhs.height - rhs.height) <= epsilon
    }

    private func pointApproximatelyEqual(_ lhs: CGPoint, _ rhs: CGPoint, epsilon: CGFloat = 0.5) -> Bool {
        abs(lhs.x - rhs.x) <= epsilon && abs(lhs.y - rhs.y) <= epsilon
    }

    private func dropZoneOverlayContainerView() -> NSView {
        superview ?? self
    }

    private func bringPaneDropTargetToFrontIfNeeded() {
        if paneDropTargetView.superview !== self || subviews.last !== paneDropTargetView {
            addSubview(paneDropTargetView, positioned: .above, relativeTo: nil)
        }
    }

    private func attachDropZoneOverlayIfNeeded() {
        // Keep the hover indicator outside the hosted terminal subtree so it stays purely additive
        // and cannot invalidate the scroll/surface layout that Ghostty renders into.
        let container = dropZoneOverlayContainerView()
        if dropZoneOverlayView.superview !== container {
            dropZoneOverlayView.removeFromSuperview()
            if container === self {
                addSubview(dropZoneOverlayView, positioned: .above, relativeTo: nil)
            } else {
                container.addSubview(dropZoneOverlayView, positioned: .above, relativeTo: self)
            }
#if DEBUG
            logDropZoneOverlay(event: "attach", zone: activeDropZone ?? pendingDropZone, frame: dropZoneOverlayView.frame)
#endif
            return
        }

        guard container !== self else { return }
        guard let hostedIndex = container.subviews.firstIndex(of: self),
              let overlayIndex = container.subviews.firstIndex(of: dropZoneOverlayView),
              overlayIndex <= hostedIndex else { return }
        container.addSubview(dropZoneOverlayView, positioned: .above, relativeTo: self)
    }

    private func applyDropZoneOverlayFrame(_ frame: CGRect) {
        if Self.rectApproximatelyEqual(dropZoneOverlayView.frame, frame) { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dropZoneOverlayView.frame = frame
        CATransaction.commit()
    }

#if DEBUG
    private static func isDragMouseEvent(_ eventType: NSEvent.EventType?) -> Bool {
        switch eventType {
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return true
        default:
            return false
        }
    }

    private func hasActiveDragLoggingContext() -> Bool {
        let pasteboardTypes = NSPasteboard(name: .drag).types
        let hasTabDrag = pasteboardTypes?.contains(Self.tabTransferPasteboardType) == true
        let hasSidebarDrag = pasteboardTypes?.contains(Self.sidebarTabReorderPasteboardType) == true
        let eventType = NSApp.currentEvent?.type
        return activeDropZone != nil ||
            pendingDropZone != nil ||
            ((hasTabDrag || hasSidebarDrag) && Self.isDragMouseEvent(eventType))
    }

    private func logDragGeometryChange(event: String, old: CGPoint, new: CGPoint) {
        guard hasActiveDragLoggingContext() else { return }

        let surface = surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil"
        let overlaySuperviewClass = dropZoneOverlayView.superview.map { String(describing: type(of: $0)) } ?? "nil"
        let signature =
            "\(event)|\(surface)|\(String(format: "%.1f,%.1f", old.x, old.y))|" +
            "\(String(format: "%.1f,%.1f", new.x, new.y))|\(overlaySuperviewClass)|\(dropZoneOverlayView.isHidden ? 1 : 0)"
        guard lastDragGeometryLogSignature != signature else { return }
        lastDragGeometryLogSignature = signature
        cmuxDebugLog(
            "terminal.dragGeometry event=\(event) surface=\(surface) " +
            "old=\(String(format: "%.1f,%.1f", old.x, old.y)) " +
            "new=\(String(format: "%.1f,%.1f", new.x, new.y)) " +
            "overlaySuper=\(overlaySuperviewClass) " +
            "overlayExternal=\(dropZoneOverlayView.superview === self ? 0 : 1) " +
            "overlayHidden=\(dropZoneOverlayView.isHidden ? 1 : 0)"
        )
    }

    private func logLayoutDuringActiveDrag(targetSize: CGSize) {
        let pasteboardTypes = NSPasteboard(name: .drag).types
        let hasTabDrag = pasteboardTypes?.contains(Self.tabTransferPasteboardType) == true
        let hasSidebarDrag = pasteboardTypes?.contains(Self.sidebarTabReorderPasteboardType) == true
        let eventType = NSApp.currentEvent?.type
        let hasActiveDrag =
            activeDropZone != nil ||
            pendingDropZone != nil ||
            ((hasTabDrag || hasSidebarDrag) && Self.isDragMouseEvent(eventType))
        guard hasActiveDrag else { return }

        dragLayoutLogSequence &+= 1
        let surface = surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil"
        let activeZone = activeDropZone.map { String(describing: $0) } ?? "none"
        let pendingZone = pendingDropZone.map { String(describing: $0) } ?? "none"
        let event = eventType.map { String(describing: $0) } ?? "nil"
        let overlaySuperviewClass = dropZoneOverlayView.superview.map { String(describing: type(of: $0)) } ?? "nil"
        cmuxDebugLog(
            "terminal.layout.drag surface=\(surface) seq=\(dragLayoutLogSequence) " +
            "activeZone=\(activeZone) pendingZone=\(pendingZone) " +
            "hasTabDrag=\(hasTabDrag ? 1 : 0) hasSidebarDrag=\(hasSidebarDrag ? 1 : 0) " +
            "event=\(event) inWindow=\(window != nil ? 1 : 0) " +
            "overlaySuper=\(overlaySuperviewClass) overlayExternal=\(dropZoneOverlayView.superview === self ? 0 : 1) " +
            "scrollOrigin=\(String(format: "%.1f,%.1f", scrollView.contentView.bounds.origin.x, scrollView.contentView.bounds.origin.y)) " +
            "surfaceOrigin=\(String(format: "%.1f,%.1f", surfaceView.frame.origin.x, surfaceView.frame.origin.y)) " +
            "bounds=\(String(format: "%.1fx%.1f", bounds.width, bounds.height)) " +
            "target=\(String(format: "%.1fx%.1f", targetSize.width, targetSize.height))"
        )
    }
#endif

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers.removeAll()
        guard let window else { return }
        windowObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isActive, self.surfaceView.isVisibleInUI, let tabId = self.surfaceView.tabId, let surfaceId = self.surfaceView.terminalSurface?.id, self.matchesCurrentTerminalFocusTarget(tabId: tabId, surfaceId: surfaceId) else { return }
#if DEBUG
            cmuxDebugLog("find.window.didBecomeKey surface=\(self.surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") searchActive=\(self.surfaceView.terminalSurface?.searchState != nil) focusTarget=\(self.searchFocusTarget) firstResponder=\(String(describing: self.window?.firstResponder))")
#endif
            self.scheduleAutomaticFirstResponderApply(reason: "didBecomeKey")
        })
        windowObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            guard let self, let window = self.window else { return }
            let searchActive = self.surfaceView.terminalSurface?.searchState != nil
            // Losing key window does not always trigger first-responder resignation, so force
            // the focused terminal view to yield responder to keep Ghostty cursor/focus state in sync.
            if let fr = window.firstResponder as? NSView,
               fr === self.surfaceView || fr.isDescendant(of: self.surfaceView) {
#if DEBUG
                cmuxDebugLog("find.window.didResignKey surface=\(self.surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") searchActive=\(searchActive) resigningFirstResponder")
#endif
                window.makeFirstResponder(nil)
            } else {
#if DEBUG
                cmuxDebugLog("find.window.didResignKey surface=\(self.surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") searchActive=\(searchActive) firstResponder=\(String(describing: window.firstResponder)) (not terminal, skipping)")
#endif
            }
        })
        if window.isKeyWindow {
            scheduleAutomaticFirstResponderApply(reason: "viewDidMoveToWindow")
        }
    }

    func attachSurface(_ terminalSurface: TerminalSurface) {
        surfaceView.attachSurface(terminalSurface)
        // Preserve the bootstrap 800x600 surface until portal reattach churn
        // has produced a real host size instead of a transient 1x1 placeholder.
        guard bounds.width > 1, bounds.height > 1 else { return }
        _ = synchronizeGeometryAndContent()
    }

    func setFocusHandler(_ handler: (() -> Void)?) {
        guard let handler else {
            surfaceView.onFocus = nil
            return
        }
        surfaceView.onFocus = { [weak self] in
            // When the terminal surface gains focus (click, tab, etc.), update the
            // search focus target so window reactivation restores terminal focus.
            if self?.surfaceView.terminalSurface?.searchState != nil {
                self?.searchFocusTarget = .terminal
            }
            handler()
        }
    }

    func beginFindEscapeSuppression() {
        surfaceView.beginFindEscapeSuppression()
    }

    func setTriggerFlashHandler(_ handler: (() -> Void)?) {
        surfaceView.onTriggerFlash = handler
    }

    /// Applies the host-layer terminal fill and optionally clears the shared backdrop behind it.
    func setBackgroundColor(_ color: NSColor, clearsSharedWindowBackdrop: Bool = false) {
        guard let layer = backgroundView.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        synchronizeSharedBackdropCutout(visible: clearsSharedWindowBackdrop)
        layer.backgroundColor = color.cgColor
        layer.isOpaque = color.alphaComponent >= 1.0
        CATransaction.commit()
        // The viewport border strokes the window-chrome separator color, which tracks the
        // terminal background/theme. Repaint it when the background changes (e.g. theme
        // switch) so a connected iOS device's visible-area border stays in sync.
        if !mobileViewportBorderOverlayView.isHidden {
            mobileViewportBorderOverlayView.needsDisplay = true
        }
    }

    /// Keeps the shared-backdrop cutout view present only while a pane-local fill needs it.
    private func synchronizeSharedBackdropCutout(visible: Bool) {
        if visible {
            let cutoutView = sharedBackdropCutoutView ?? makeSharedBackdropCutoutView()
            _ = setFrameIfNeeded(cutoutView, to: bounds)
            return
        }

        sharedBackdropCutoutView?.removeFromSuperview()
        sharedBackdropCutoutView = nil
    }

    /// Creates the Core Image filtered view that subtracts pane-local fills from shared backdrop.
    ///
    /// AppKit requires `layerUsesCoreImageFilters` to be configured before display, so the
    /// cutout view is created lazily only when a pane-local OSC background override needs it.
    private func makeSharedBackdropCutoutView() -> NSView {
        let sharedBackdropCutoutFilter = TerminalSharedBackdropCutoutFilter()
        sharedBackdropCutoutFilter.name = "terminalSharedBackdropCutout"
        let cutoutView = NSView(frame: bounds)
        cutoutView.wantsLayer = true
        cutoutView.layerUsesCoreImageFilters = true
        cutoutView.compositingFilter = sharedBackdropCutoutFilter
        cutoutView.layer?.backgroundColor = NSColor.white.cgColor
        cutoutView.layer?.isOpaque = true
        addSubview(cutoutView, positioned: .below, relativeTo: backgroundView)
        sharedBackdropCutoutView = cutoutView
        return cutoutView
    }

    func setInactiveOverlay(color: NSColor, opacity: CGFloat, visible: Bool) {
        let clampedOpacity = max(0, min(1, opacity))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        inactiveOverlayView.layer?.backgroundColor = color.withAlphaComponent(clampedOpacity).cgColor
        inactiveOverlayView.isHidden = !(visible && clampedOpacity > 0.0001)
        CATransaction.commit()
    }

    func setNotificationRing(visible: Bool) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.setNotificationRing(visible: visible)
            }
            return
        }

        let targetHidden = !visible
        let targetOpacity: Float = visible ? 1 : 0
        guard notificationRingOverlayView.isHidden != targetHidden ||
                notificationRingLayer.opacity != targetOpacity else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        notificationRingOverlayView.isHidden = targetHidden
        notificationRingLayer.opacity = targetOpacity
        CATransaction.commit()
    }

    private func cancelDeferredSearchOverlayMutation() {
        deferredSearchOverlayMutationWorkItem?.cancel()
        deferredSearchOverlayMutationWorkItem = nil
    }

    private func scheduleDeferredSearchOverlayMutation(
        generation: UInt64,
        _ mutation: @escaping () -> Void
    ) {
        cancelDeferredSearchOverlayMutation()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.searchOverlayMutationGeneration == generation else { return }
            self.deferredSearchOverlayMutationWorkItem = nil
            mutation()
        }
        deferredSearchOverlayMutationWorkItem = work
        DispatchQueue.main.async(execute: work)
    }

    private func cancelImageTransferIndicatorShow() {
        imageTransferIndicatorShowWorkItem?.cancel()
        imageTransferIndicatorShowWorkItem = nil
    }

    private func updateImageTransferIndicatorZOrder(relativeTo overlay: NSView?) {
        guard !imageTransferIndicatorContainerView.isHidden else { return }
        if let overlay, overlay.superview === self {
            addSubview(imageTransferIndicatorContainerView, positioned: .above, relativeTo: overlay)
            return
        }
        if keyboardCopyModeBadgeContainerView.superview === self,
           !keyboardCopyModeBadgeContainerView.isHidden {
            addSubview(
                imageTransferIndicatorContainerView,
                positioned: .above,
                relativeTo: keyboardCopyModeBadgeContainerView
            )
            return
        }
        addSubview(imageTransferIndicatorContainerView, positioned: .above, relativeTo: nil)
    }

    private func updateKeyboardCopyModeBadgeZOrder(relativeTo overlay: NSView?) {
        guard !keyboardCopyModeBadgeContainerView.isHidden else { return }
        if let overlay, overlay.superview === self {
            addSubview(keyboardCopyModeBadgeContainerView, positioned: .above, relativeTo: overlay)
        } else {
            addSubview(keyboardCopyModeBadgeContainerView, positioned: .above, relativeTo: nil)
        }
        updateImageTransferIndicatorZOrder(relativeTo: overlay)
    }

    @objc private func handleImageTransferCancel() {
        guard let operation = activeImageTransferOperation else { return }
        let onCancel = activeImageTransferCancelHandler
        guard operation.cancel() else { return }
        endImageTransferIndicator(for: operation)
        onCancel?()
    }

    func beginImageTransferIndicator(
        for operation: TerminalImageTransferOperation,
        onCancel: @escaping () -> Void
    ) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.beginImageTransferIndicator(for: operation, onCancel: onCancel)
            }
            return
        }

        cancelImageTransferIndicatorShow()
        activeImageTransferOperation = operation
        activeImageTransferCancelHandler = onCancel
        imageTransferIndicatorSpinner.stopAnimation(nil)
        imageTransferIndicatorContainerView.isHidden = true

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.activeImageTransferOperation === operation else { return }
            guard !operation.isCancelled else { return }
            self.imageTransferIndicatorShowWorkItem = nil
            self.imageTransferIndicatorSpinner.startAnimation(nil)
            self.imageTransferIndicatorContainerView.isHidden = false
            self.updateImageTransferIndicatorZOrder(relativeTo: self.searchOverlayHostingView)
        }
        imageTransferIndicatorShowWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func endImageTransferIndicator(for operation: TerminalImageTransferOperation?) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.endImageTransferIndicator(for: operation)
            }
            return
        }

        if let operation,
           activeImageTransferOperation !== operation {
            return
        }

        cancelImageTransferIndicatorShow()
        activeImageTransferOperation = nil
        activeImageTransferCancelHandler = nil
        imageTransferIndicatorSpinner.stopAnimation(nil)
        imageTransferIndicatorContainerView.isHidden = true
    }

    private func makeSearchOverlayRootView(
        terminalSurface: TerminalSurface,
        searchState: TerminalSurface.SearchState
    ) -> SurfaceSearchOverlay {
        SurfaceSearchOverlay(
            tabId: terminalSurface.tabId,
            surfaceId: terminalSurface.id,
            searchState: searchState,
            canApplyFocusRequest: { [weak self] in
                self?.canApplyMountedSearchFieldFocusRequest() ?? false
            },
            onNavigateSearch: { [weak terminalSurface] action in
                _ = terminalSurface?.performBindingAction(action)
            },
            onFieldDidFocus: { [weak self, weak terminalSurface] in
                self?.searchFocusTarget = .searchField
                terminalSurface?.setFocus(false)
            },
            onClose: { [weak self, weak terminalSurface] in
                terminalSurface?.searchState = nil
                self?.moveFocus()
            }
        )
    }

    private func findEditableSearchField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable {
            return field
        }
        for subview in view.subviews {
            if let field = findEditableSearchField(in: subview) {
                return field
            }
        }
        return nil
    }

    private func mountedSearchFieldIfAvailable() -> NSTextField? {
        guard let overlay = searchOverlayHostingView,
              overlay.superview === self else {
            return nil
        }
        return findEditableSearchField(in: overlay)
    }

    private func mountedSearchFieldOwnsResponder(
        _ responder: NSResponder?,
        field: NSTextField? = nil
    ) -> Bool {
        guard let responder else { return false }
        guard let field = field ?? mountedSearchFieldIfAvailable() else { return false }
        return responder === field || field.currentEditor() === responder
    }

    private func resolvedKeyboardFocusOwnerView(for responder: NSResponder?) -> NSView? {
        guard let responder else { return nil }

        let mountedSearchField = mountedSearchFieldIfAvailable()
        if mountedSearchFieldOwnsResponder(responder, field: mountedSearchField) {
            return mountedSearchField
        }

        if let editor = responder as? NSTextView,
           editor.isFieldEditor {
            var current = editor.nextResponder
            while let next = current {
                if let view = next as? NSView {
                    return view
                }
                current = next.nextResponder
            }
            return editor.superview ?? editor
        }

        return responder as? NSView
    }

    private func canApplyMountedSearchFieldFocusRequest() -> Bool {
        guard let terminalSurface = surfaceView.terminalSurface,
              let app = AppDelegate.shared,
              let manager = app.tabManagerFor(tabId: terminalSurface.tabId),
              manager.selectedTabId == terminalSurface.tabId,
              let workspace = manager.tabs.first(where: { $0.id == terminalSurface.tabId }) else {
            return false
        }
        return workspace.focusedPanelId == terminalSurface.id
    }

    private func requestMountedSearchFieldFocus(
        generation: UInt64,
        force: Bool,
        attemptsRemaining: Int = 4
    ) {
        guard searchOverlayMutationGeneration == generation else { return }
        guard force || searchFocusTarget == .searchField else { return }
        guard canApplyMountedSearchFieldFocusRequest() else { return }
        guard let overlay = searchOverlayHostingView,
              overlay.superview === self,
              let window,
              window.isKeyWindow else { return }

        guard let field = findEditableSearchField(in: overlay) else {
            guard attemptsRemaining > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                self?.requestMountedSearchFieldFocus(
                    generation: generation,
                    force: force,
                    attemptsRemaining: attemptsRemaining - 1
                )
            }
            return
        }

        let firstResponder = window.firstResponder
        let alreadyFocused = mountedSearchFieldOwnsResponder(firstResponder, field: field)
        guard !alreadyFocused else { return }

        surfaceView.terminalSurface?.setFocus(false)
        let result = window.makeFirstResponder(field)
#if DEBUG
        cmuxDebugLog(
            "find.mountedFieldFocus surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
            "result=\(result ? 1 : 0) attemptsRemaining=\(attemptsRemaining) " +
            "firstResponder=\(String(describing: window.firstResponder))"
        )
#endif
        guard !result, attemptsRemaining > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.requestMountedSearchFieldFocus(
                generation: generation,
                force: force,
                attemptsRemaining: attemptsRemaining - 1
            )
        }
    }

    func setSearchOverlay(searchState: TerminalSurface.SearchState?) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.setSearchOverlay(searchState: searchState)
            }
            return
        }

        searchOverlayMutationGeneration &+= 1
        let mutationGeneration = searchOverlayMutationGeneration

        // Layering contract: keep terminal Cmd+F UI inside this portal-hosted AppKit view.
        // SwiftUI panel-level overlays can fall behind portal-hosted terminal surfaces.
        guard let terminalSurface = surfaceView.terminalSurface,
              let searchState else {
            let hadOverlay = searchOverlayHostingView != nil
            lastSearchOverlayStateID = nil
            searchFocusTarget = .searchField
            guard hadOverlay else {
                cancelDeferredSearchOverlayMutation()
                return
            }
#if DEBUG
            cmuxDebugLog("find.setSearchOverlay REMOVE surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") hadOverlay=\(hadOverlay)")
#endif
            scheduleDeferredSearchOverlayMutation(generation: mutationGeneration) { [weak self] in
                self?.searchOverlayHostingView?.removeFromSuperview()
                self?.searchOverlayHostingView = nil
            }
            return
        }

        let searchStateID = ObjectIdentifier(searchState)
        if let overlay = searchOverlayHostingView,
           lastSearchOverlayStateID == searchStateID,
           overlay.superview === self {
            cancelDeferredSearchOverlayMutation()
            _ = setFrameIfNeeded(overlay, to: bounds)
            updateKeyboardCopyModeBadgeZOrder(relativeTo: overlay)
            return
        }

        let hadOverlay = searchOverlayHostingView != nil
#if DEBUG
        cmuxDebugLog("find.setSearchOverlay MOUNT surface=\(terminalSurface.id.uuidString.prefix(5)) existingOverlay=\(hadOverlay ? "yes(update)" : "no(create)")")
#endif

        let rootView = makeSearchOverlayRootView(
            terminalSurface: terminalSurface,
            searchState: searchState
        )

        if let overlay = searchOverlayHostingView {
            overlay.rootView = rootView
            lastSearchOverlayStateID = searchStateID
            if overlay.superview !== self {
                scheduleDeferredSearchOverlayMutation(generation: mutationGeneration) { [weak self, weak overlay] in
                    guard let self, let overlay else { return }
                    overlay.removeFromSuperview()
                    overlay.frame = self.bounds
                    overlay.autoresizingMask = [.width, .height]
                    self.addSubview(overlay)
                    self.updateKeyboardCopyModeBadgeZOrder(relativeTo: overlay)
                    self.requestMountedSearchFieldFocus(
                        generation: mutationGeneration,
                        force: false
                    )
                }
                return
            }
            cancelDeferredSearchOverlayMutation()
            _ = setFrameIfNeeded(overlay, to: bounds)
            updateKeyboardCopyModeBadgeZOrder(relativeTo: overlay)
            return
        }

        searchFocusTarget = .searchField
        let overlay = TerminalSearchOverlayHostingView(rootView: rootView, surfaceView: surfaceView)
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        searchOverlayHostingView = overlay
        lastSearchOverlayStateID = searchStateID
        scheduleDeferredSearchOverlayMutation(generation: mutationGeneration) { [weak self, weak overlay] in
            guard let self, let overlay else { return }
            guard self.searchOverlayHostingView === overlay else { return }
            overlay.removeFromSuperview()
            overlay.frame = self.bounds
            overlay.autoresizingMask = [.width, .height]
            self.addSubview(overlay)
            self.updateKeyboardCopyModeBadgeZOrder(relativeTo: overlay)
            self.requestMountedSearchFieldFocus(
                generation: mutationGeneration,
                force: true
            )
        }
    }

    func syncKeyStateIndicator(text: String?) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.syncKeyStateIndicator(text: text)
            }
            return
        }

        if let text, !text.isEmpty {
            keyboardCopyModeBadgeLabel.stringValue = text
            keyboardCopyModeBadgeIconView.setAccessibilityLabel(text)
            let needsReorder = keyboardCopyModeBadgeContainerView.isHidden
                || keyboardCopyModeBadgeContainerView.superview !== self
                || subviews.last !== keyboardCopyModeBadgeContainerView
            keyboardCopyModeBadgeContainerView.isHidden = false
            if needsReorder {
                updateKeyboardCopyModeBadgeZOrder(relativeTo: searchOverlayHostingView)
            }
            return
        }

        keyboardCopyModeBadgeIconView.setAccessibilityLabel(terminalKeyTableIndicatorAccessibilityLabel)
        keyboardCopyModeBadgeContainerView.isHidden = true
    }

    func refreshHostBackgroundAfterGhosttyConfigReload() {
        _ = synchronizeGeometryAndContent()
        surfaceView.applySurfaceBackground()
        surfaceView.applyWindowBackgroundIfActive()
    }

    func reapplySurfaceColorSchemeAfterGhosttyConfigReload(
        preferredColorScheme: GhosttyConfig.ColorSchemePreference
    ) {
        surfaceView.applySurfaceColorScheme(
            force: true,
            preferredColorScheme: preferredColorScheme
        )
    }

    private func dropZoneOverlayFrame(for zone: DropZone, in size: CGSize) -> CGRect {
        let localFrame = PaneDropRouting.compactOverlayFrame(for: zone, in: size)

        let container = dropZoneOverlayView.superview ?? superview
        guard let container, container !== self else { return localFrame }
        return container.convert(localFrame, from: self)
    }

    private static func rectApproximatelyEqual(_ lhs: CGRect, _ rhs: CGRect, epsilon: CGFloat = 0.5) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= epsilon &&
            abs(lhs.origin.y - rhs.origin.y) <= epsilon &&
            abs(lhs.size.width - rhs.size.width) <= epsilon &&
            abs(lhs.size.height - rhs.size.height) <= epsilon
    }

    func setDropZoneOverlay(zone: DropZone?) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.setDropZoneOverlay(zone: zone)
            }
            return
        }

        if let zone, (bounds.width <= 2 || bounds.height <= 2) {
            pendingDropZone = zone
#if DEBUG
            logDropZoneOverlay(event: "deferZeroBounds", zone: zone, frame: nil)
#endif
            return
        }

        let previousZone = activeDropZone
        activeDropZone = zone
        pendingDropZone = nil

        if let zone {
#if DEBUG
            if window == nil {
                logDropZoneOverlay(event: "showNoWindow", zone: zone, frame: nil)
            }
#endif
            attachDropZoneOverlayIfNeeded()
            let targetFrame = dropZoneOverlayFrame(for: zone, in: bounds.size)
            let previousFrame = dropZoneOverlayView.frame
            let isSameFrame = Self.rectApproximatelyEqual(previousFrame, targetFrame)
            let needsFrameUpdate = !isSameFrame
            let zoneChanged = previousZone != zone

            if !dropZoneOverlayView.isHidden && !needsFrameUpdate && !zoneChanged {
                return
            }

            dropZoneOverlayAnimationGeneration &+= 1
            dropZoneOverlayView.layer?.removeAllAnimations()

            if dropZoneOverlayView.isHidden {
                applyDropZoneOverlayFrame(targetFrame)
                dropZoneOverlayView.alphaValue = 0
                dropZoneOverlayView.isHidden = false
#if DEBUG
                recordDropOverlayShowAnimation()
#endif
#if DEBUG
                logDropZoneOverlay(event: "show", zone: zone, frame: targetFrame)
#endif

                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    dropZoneOverlayView.animator().alphaValue = 1
                } completionHandler: { [weak self] in
#if DEBUG
                    guard let self else { return }
                    guard self.activeDropZone == zone else { return }
                    self.logDropZoneOverlay(event: "showComplete", zone: zone, frame: targetFrame)
#endif
                }
                return
            }

#if DEBUG
            if needsFrameUpdate || zoneChanged {
                logDropZoneOverlay(event: "update", zone: zone, frame: targetFrame)
            }
#endif
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                if needsFrameUpdate {
                    dropZoneOverlayView.animator().frame = targetFrame
                }
                if dropZoneOverlayView.alphaValue < 1 {
                    dropZoneOverlayView.animator().alphaValue = 1
                }
            }
        } else {
            guard !dropZoneOverlayView.isHidden else { return }
            dropZoneOverlayAnimationGeneration &+= 1
            let animationGeneration = dropZoneOverlayAnimationGeneration
            dropZoneOverlayView.layer?.removeAllAnimations()
#if DEBUG
            logDropZoneOverlay(event: "hide", zone: nil, frame: nil)
#endif

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                dropZoneOverlayView.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                guard let self else { return }
                guard self.dropZoneOverlayAnimationGeneration == animationGeneration else { return }
                guard self.activeDropZone == nil else { return }
                self.dropZoneOverlayView.isHidden = true
                self.dropZoneOverlayView.alphaValue = 1
#if DEBUG
                self.logDropZoneOverlay(event: "hideComplete", zone: nil, frame: nil)
#endif
            }
        }
    }

    func setPaneDropContext(_ context: TerminalPaneDropContext?) {
        paneDropTargetView.dropContext = context
        if context == nil {
            paneDropTargetView.draggingExited(nil)
        }
    }

    func paneDropTargetForDrop(at localPoint: NSPoint) -> TerminalPaneDropTargetView? {
        guard bounds.contains(localPoint) else { return nil }
        let pointInTarget = paneDropTargetView.convert(localPoint, from: self)
        guard paneDropTargetView.bounds.contains(pointInTarget) else { return nil }
        guard !paneDropTargetView.shouldDeferToPaneTabBar(at: pointInTarget) else { return nil }
        return paneDropTargetView
    }

#if DEBUG
    private func logDropZoneOverlay(event: String, zone: DropZone?, frame: CGRect?) {
        let surface = surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil"
        let zoneText = zone.map { String(describing: $0) } ?? "none"
        let boundsText = String(format: "%.1fx%.1f", bounds.width, bounds.height)
        let overlaySuperviewClass = dropZoneOverlayView.superview.map { String(describing: type(of: $0)) } ?? "nil"
        let scrollOriginText = String(
            format: "%.1f,%.1f",
            scrollView.contentView.bounds.origin.x,
            scrollView.contentView.bounds.origin.y
        )
        let surfaceOriginText = String(
            format: "%.1f,%.1f",
            surfaceView.frame.origin.x,
            surfaceView.frame.origin.y
        )
        let frameText: String
        if let frame {
            frameText = String(
                format: "%.1f,%.1f %.1fx%.1f",
                frame.origin.x, frame.origin.y, frame.width, frame.height
            )
        } else {
            frameText = "-"
        }
        let signature =
            "\(event)|\(surface)|\(zoneText)|\(boundsText)|\(frameText)|\(overlaySuperviewClass)|" +
            "\(scrollOriginText)|\(surfaceOriginText)|\(dropZoneOverlayView.isHidden ? 1 : 0)"
        guard lastDropZoneOverlayLogSignature != signature else { return }
        lastDropZoneOverlayLogSignature = signature
        cmuxDebugLog(
            "terminal.dropOverlay event=\(event) surface=\(surface) zone=\(zoneText) " +
            "hidden=\(dropZoneOverlayView.isHidden ? 1 : 0) bounds=\(boundsText) frame=\(frameText) " +
            "overlaySuper=\(overlaySuperviewClass) overlayExternal=\(dropZoneOverlayView.superview === self ? 0 : 1) " +
            "scrollOrigin=\(scrollOriginText) surfaceOrigin=\(surfaceOriginText)"
        )
    }
#endif

    func triggerFlash(style: FlashStyle = .navigation) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lastFlashStyle = style
            #if DEBUG
            if let surfaceId = self.surfaceView.terminalSurface?.id {
                Self.recordFlash(for: surfaceId)
            }
#endif
            self.updateFlashPath(style: style)
            self.updateFlashAppearance(style: style)
            self.flashLayer.removeAllAnimations()
            self.flashLayer.opacity = 0
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.values = FocusFlashPattern.values.map { NSNumber(value: $0) }
            animation.keyTimes = FocusFlashPattern.keyTimes.map { NSNumber(value: $0) }
            animation.duration = FocusFlashPattern.duration
            animation.timingFunctions = FocusFlashPattern.curves.map { curve in
                switch curve {
                case .easeIn:
                    return CAMediaTimingFunction(name: .easeIn)
                case .easeOut:
                    return CAMediaTimingFunction(name: .easeOut)
                }
            }
            self.flashLayer.add(animation, forKey: "cmux.flash")
        }
    }

    func setVisibleInUI(_ visible: Bool) {
        let wasVisible = surfaceView.isVisibleInUI
        surfaceView.setVisibleInUI(visible)
        isHidden = !visible
        if wasVisible != visible, lastRequestedPortalOcclusionVisible != visible {
            lastRequestedPortalOcclusionVisible = visible
            surfaceView.terminalSurface?.setOcclusion(visible)
        }
#if DEBUG
        if wasVisible != visible {
            let transition = "\(wasVisible ? 1 : 0)->\(visible ? 1 : 0)"
            let suffix = debugVisibilityStateSuffix(transition: transition)
            debugLogWorkspaceSwitchTiming(
                event: "ws.term.visible",
                suffix: suffix
            )
        }
#endif
        if wasVisible != visible {
            NotificationCenter.default.post(
                name: .terminalPortalVisibilityDidChange,
                object: self,
                userInfo: [
                    GhosttyNotificationKey.surfaceId: surfaceView.terminalSurface?.id as Any,
                    GhosttyNotificationKey.tabId: surfaceView.tabId as Any
                ]
            )
        }
        if !visible {
            // If we were focused, yield first responder.
            if let window = uiWindow, let fr = window.firstResponder as? NSView,
               fr === surfaceView || fr.isDescendant(of: surfaceView) {
                window.makeFirstResponder(nil)
            }
        } else if !wasVisible {
            // Workspace/sidebar selection can make an already-sized terminal visible again
            // without a portal frame delta or a focus handoff. Reuse the portal refresh
            // path so the Metal layer is nudged immediately on plain visibility restores.
            refreshSurfaceNow(reason: "setVisibleInUI")
            scheduleAutomaticFirstResponderApply(reason: "setVisibleInUI")
        }
    }

    var debugPortalVisibleInUI: Bool {
        surfaceView.isVisibleInUI
    }

    var debugPortalActive: Bool {
        isActive
    }

    var debugPortalFrameInWindow: CGRect {
        guard uiWindow != nil else { return .zero }
        return convert(bounds, to: nil)
    }

    func setActive(_ active: Bool) {
        let wasActive = isActive
        isActive = active
#if DEBUG
        if wasActive != active {
            let transition = "\(wasActive ? 1 : 0)->\(active ? 1 : 0)"
            let suffix = debugVisibilityStateSuffix(transition: transition)
            debugLogWorkspaceSwitchTiming(
                event: "ws.term.active",
                suffix: suffix
            )
        }
#endif
        if active && !wasActive {
            scheduleAutomaticFirstResponderApply(reason: "setActive")
        } else if !active {
            resignOwnedFirstResponderIfNeeded(reason: "setActive(false)")
        }
    }

#if DEBUG
    private func debugLogWorkspaceSwitchTiming(event: String, suffix: String) {
        guard let snapshot = AppDelegate.shared?.tabManager?.debugCurrentWorkspaceSwitchSnapshot() else {
            cmuxDebugLog("\(event) id=none \(suffix)")
            return
        }
        let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
        cmuxDebugLog("\(event) id=\(snapshot.id) dt=\(String(format: "%.2fms", dtMs)) \(suffix)")
    }

    private func debugFirstResponderLabel() -> String {
        guard let window = uiWindow, let firstResponder = window.firstResponder else { return "nil" }
        if let view = firstResponder as? NSView {
            if view === surfaceView {
                return "surfaceView"
            }
            if view.isDescendant(of: surfaceView) {
                return "surfaceDescendant"
            }
            return String(describing: type(of: view))
        }
        return String(describing: type(of: firstResponder))
    }

    private func debugVisibilityStateSuffix(transition: String) -> String {
        let surface = surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil"
        let hiddenInHierarchy = (isHiddenOrHasHiddenAncestor || surfaceView.isHiddenOrHasHiddenAncestor) ? 1 : 0
        let inWindow = uiWindow != nil ? 1 : 0
        let hasSuperview = superview != nil ? 1 : 0
        let hostHidden = isHidden ? 1 : 0
        let surfaceHidden = surfaceView.isHidden ? 1 : 0
        let boundsText = String(format: "%.1fx%.1f", bounds.width, bounds.height)
        let frameText = String(format: "%.1fx%.1f", frame.width, frame.height)
        let responder = debugFirstResponderLabel()
        return
            "surface=\(surface) transition=\(transition) active=\(isActive ? 1 : 0) " +
            "visibleFlag=\(surfaceView.isVisibleInUI ? 1 : 0) hostHidden=\(hostHidden) surfaceHidden=\(surfaceHidden) " +
            "hiddenHierarchy=\(hiddenInHierarchy) inWindow=\(inWindow) hasSuperview=\(hasSuperview) " +
            "bounds=\(boundsText) frame=\(frameText) firstResponder=\(responder)"
    }
#endif

    func moveFocus(from previous: GhosttySurfaceScrollView? = nil, delay: TimeInterval? = nil) {
#if DEBUG
        let surfaceShort = String(self.surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil")
        let searchActive = self.surfaceView.terminalSurface?.searchState != nil
        cmuxDebugLog(
            "find.moveFocus to=\(surfaceShort) " +
            "from=\(previous?.surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
            "searchState=\(searchActive ? "active" : "nil") " +
            "delayMs=\(Int((delay ?? 0) * 1000))"
        )
#endif
        let work = { [weak self] in
            guard let self else { return }
            guard let window = self.uiWindow else { return }
#if DEBUG
            let before = String(describing: window.firstResponder)
#endif
            guard self.canRequestSurfaceFirstResponder(in: window, reason: "moveFocus") else { return }
            if let previous, previous !== self {
                _ = previous.surfaceView.resignFirstResponder()
            }
            let result = window.makeFirstResponder(self.surfaceView)
#if DEBUG
            cmuxDebugLog(
                "find.moveFocus.apply to=\(self.surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
                "result=\(result ? 1 : 0) before=\(before) after=\(String(describing: window.firstResponder))"
            )
#endif
        }

        if let delay, delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { work() }
        } else {
            if Thread.isMainThread {
                work()
            } else {
                DispatchQueue.main.async { work() }
            }
        }
    }

#if DEBUG
    @discardableResult
    func debugSimulateFileDrop(paths: [String], asImageData: Bool = false) -> Bool {
        surfaceView.debugSimulateFileDrop(paths: paths, asImageData: asImageData)
    }

    func debugPendingSurfaceSize() -> CGSize? {
        surfaceView.debugPendingSurfaceSize()
    }

    func debugRegisteredDropTypes() -> [String] {
        surfaceView.debugRegisteredDropTypes()
    }

    func debugInactiveOverlayState() -> (isHidden: Bool, alpha: CGFloat) {
        (
            inactiveOverlayView.isHidden,
            inactiveOverlayView.layer?.backgroundColor.flatMap { NSColor(cgColor: $0)?.alphaComponent } ?? 0
        )
    }

    func debugNotificationRingState() -> (isHidden: Bool, opacity: Float) {
        (
            notificationRingOverlayView.isHidden,
            notificationRingLayer.opacity
        )
    }

    struct DebugDropZoneOverlayState {
        let isHidden: Bool
        let frame: CGRect
        let isAttachedToHostedView: Bool
        let isAttachedToParentContainer: Bool
    }

    func debugDropZoneOverlayState() -> DebugDropZoneOverlayState {
        DebugDropZoneOverlayState(
            isHidden: dropZoneOverlayView.isHidden,
            frame: dropZoneOverlayView.frame,
            isAttachedToHostedView: dropZoneOverlayView.superview === self,
            isAttachedToParentContainer: dropZoneOverlayView.superview === superview
        )
    }

    func debugHasSearchOverlay() -> Bool {
        guard let overlay = searchOverlayHostingView else { return false }
        return overlay.superview === self && !overlay.isHidden
    }

    func debugSearchOverlayHostingViewForTesting() -> NSView? {
        guard let overlay = searchOverlayHostingView,
              overlay.superview === self else {
            return nil
        }
        return overlay
    }

    func debugSurfaceHasPendingLeftMouseReleaseForTesting() -> Bool {
        surfaceView.debugHasPendingLeftMouseReleaseForTesting()
    }

    func debugHasKeyboardCopyModeIndicator() -> Bool {
        keyboardCopyModeBadgeContainerView.superview === self && !keyboardCopyModeBadgeContainerView.isHidden
    }

#endif

    fileprivate var hasActiveDropZoneOverlay: Bool {
        activeDropZone != nil || pendingDropZone != nil
    }

    /// Handle file/URL drops, forwarding to the terminal as shell-escaped paths.
    func handleDroppedURLs(_ urls: [URL]) -> Bool {
        #if DEBUG
        cmuxDebugLog("terminal.swiftUIDrop surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") urls=\(urls.map(\.lastPathComponent))")
        #endif
        return surfaceView.handleDroppedFileURLs(urls)
    }

    func terminalViewForDrop(at point: NSPoint) -> GhosttyNSView? {
        guard bounds.contains(point), !isHidden else { return nil }
        return surfaceView
    }

#if DEBUG
    /// Sends a synthetic key press/release pair directly to the surface view.
    /// This exercises the same key path as real keyboard input (ghostty_surface_key),
    /// unlike sendText, which bypasses key translation.
    @discardableResult
    func debugSendSyntheticKeyPressAndReleaseForUITest(
        characters: String,
        charactersIgnoringModifiers: String,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags = []
    ) -> Bool {
        guard let window = uiWindow else { return false }
        window.makeFirstResponder(surfaceView)

        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let keyDown = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        ) else { return false }

        guard let keyUp = NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: timestamp + 0.001,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        ) else { return false }

        surfaceView.keyDown(with: keyDown)
        surfaceView.keyUp(with: keyUp)
        return true
    }

    /// Sends a synthetic Ctrl+D key press directly to the surface view.
    /// This exercises the same key path as real keyboard input (ghostty_surface_key),
    /// unlike `sendText`, which bypasses key translation.
    @discardableResult
    func sendSyntheticCtrlDForUITest(modifierFlags: NSEvent.ModifierFlags = [.control]) -> Bool {
        debugSendSyntheticKeyPressAndReleaseForUITest(
            characters: "\u{04}",
            charactersIgnoringModifiers: "d",
            keyCode: 2,
            modifierFlags: modifierFlags
        )
    }
    #endif

    func ensureFocus(
        for tabId: UUID,
        surfaceId: UUID,
        respectForeignFirstResponder: Bool = true
    ) {
        let hasUsablePortalGeometry: Bool = {
            let size = bounds.size
            return size.width > 1 && size.height > 1
        }()
        let isHiddenForFocus = isHiddenOrHasHiddenAncestor || surfaceView.isHiddenOrHasHiddenAncestor

        guard isActive else { return }
        guard let window = uiWindow else { return }
        guard surfaceView.isVisibleInUI else {
#if DEBUG
            cmuxDebugLog(
                "focus.ensure.defer surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
                "reason=not_visible"
            )
#endif
            scheduleAutomaticFirstResponderApply(reason: "ensureFocus.notVisible")
            return
        }
        guard !isHiddenForFocus, hasUsablePortalGeometry else {
#if DEBUG
            cmuxDebugLog(
                "focus.ensure.defer surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
                "reason=hidden_or_tiny hidden=\(isHiddenForFocus ? 1 : 0) " +
                "frame=\(String(format: "%.1fx%.1f", bounds.width, bounds.height))"
            )
#endif
            scheduleAutomaticFirstResponderApply(reason: "ensureFocus.hiddenOrTiny")
            return
        }

        if let terminalSurface = surfaceView.terminalSurface,
           terminalSurface.focusPlacement == .rightSidebarDock {
            guard AppDelegate.shared?.allowsTerminalKeyboardFocus(
                workspaceId: tabId,
                panelId: surfaceId,
                in: window
            ) != false else {
#if DEBUG
                dlog("focus.ensure.skip surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") reason=dockCoordinator")
#endif
                return
            }
            if terminalSurface.searchState != nil {
#if DEBUG
                cmuxDebugLog(
                    "focus.ensure.dock.search surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
                    "tab=\(tabId.uuidString.prefix(5)) panel=\(surfaceId.uuidString.prefix(5)) " +
                    "firstResponder=\(String(describing: window.firstResponder))"
                )
#endif
                restoreSearchFocus(window: window)
                return
            }
            if let fr = window.firstResponder as? NSView,
               fr === surfaceView || fr.isDescendant(of: surfaceView) {
                reassertTerminalSurfaceFocus(reason: "ensureFocus.dock.alreadyFirstResponder")
                return
            }
            if respectForeignFirstResponder,
               let firstResponder = window.firstResponder,
               shouldRespectForeignFirstResponder(firstResponder, in: window, isRightSidebarOwner: {
               AppDelegate.shared?.isRightSidebarFocusResponder($0, in: window) == true
           }) {
#if DEBUG
                let reason = firstResponder is NSText ? "textEditorFocused" : "rightSidebarFocused"
                dlog("focus.ensure.skip surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") reason=dock.\(reason)")
#endif
                return
            }
            let result = window.makeFirstResponder(surfaceView)
#if DEBUG
            cmuxDebugLog(
                "focus.ensure.dock.apply surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
                "result=\(result ? 1 : 0) firstResponder=\(String(describing: window.firstResponder))"
            )
#endif
            if isSurfaceViewFirstResponder() {
                reassertTerminalSurfaceFocus(reason: "ensureFocus.dock.afterMakeFirstResponder")
            }
            return
        }

        guard let delegate = AppDelegate.shared,
              let tabManager = delegate.tabManagerFor(tabId: tabId) ?? delegate.tabManager,
              tabManager.selectedTabId == tabId else {
            scheduleAutomaticFirstResponderApply(reason: "ensureFocus.inactiveTab")
            return
        }

        guard let tab = tabManager.tabs.first(where: { $0.id == tabId }),
              let tabIdForSurface = tab.surfaceIdFromPanelId(surfaceId),
              let paneId = tab.bonsplitController.allPaneIds.first(where: { paneId in
                  tab.bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == tabIdForSurface })
              }) else {
            scheduleAutomaticFirstResponderApply(reason: "ensureFocus.missingPane")
            return
        }

        guard tab.bonsplitController.selectedTab(inPane: paneId)?.id == tabIdForSurface,
              tab.bonsplitController.focusedPaneId == paneId else {
            scheduleAutomaticFirstResponderApply(reason: "ensureFocus.unfocusedPane")
            return
        }

        guard delegate.allowsTerminalKeyboardFocus(workspaceId: tabId, panelId: surfaceId, in: window) else {
#if DEBUG
            dlog("focus.ensure.skip surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") reason=coordinatorRightSidebar")
#endif
            return
        }

        // Search focus restoration — only after confirming this is the active tab/pane.
        if surfaceView.terminalSurface?.searchState != nil {
#if DEBUG
            cmuxDebugLog(
                "focus.ensure.search surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
                "tab=\(tabId.uuidString.prefix(5)) panel=\(surfaceId.uuidString.prefix(5)) " +
                "firstResponder=\(String(describing: window.firstResponder))"
            )
#endif
            restoreSearchFocus(window: window)
            return
        }

        if let fr = window.firstResponder as? NSView,
           fr === surfaceView || fr.isDescendant(of: surfaceView) {
            reassertTerminalSurfaceFocus(reason: "ensureFocus.alreadyFirstResponder")
            return
        }

        // Layout and visibility reconciliation can ask the active terminal to
        // reassert focus after a sidebar/text owner has already accepted focus.
        // Respect those explicit AppKit first responders unless the terminal
        // surface already owns focus.
        if respectForeignFirstResponder,
           let firstResponder = window.firstResponder,
           shouldRespectForeignFirstResponder(firstResponder, in: window, isRightSidebarOwner: {
               AppDelegate.shared?.isRightSidebarFocusResponder($0, in: window) == true
           }) {
#if DEBUG
            let reason = firstResponder is NSText ? "textEditorFocused" : "rightSidebarFocused"
            dlog("focus.ensure.skip surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") reason=\(reason)")
#endif
            return
        }

        if !window.isKeyWindow {
            guard shouldAllowEnsureFocusWindowActivation(
                activeTabManager: delegate.tabManager,
                targetTabManager: tabManager,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow,
                targetWindow: window
            ) else {
                return
            }
            window.makeKeyAndOrderFront(nil)
        }
        let result = window.makeFirstResponder(surfaceView)
#if DEBUG
        cmuxDebugLog(
            "focus.ensure.apply surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
            "tab=\(tabId.uuidString.prefix(5)) panel=\(surfaceId.uuidString.prefix(5)) " +
            "result=\(result ? 1 : 0) firstResponder=\(String(describing: window.firstResponder))"
        )
#endif

        if !isSurfaceViewFirstResponder() {
            scheduleAutomaticFirstResponderApply(reason: "ensureFocus.afterMakeFirstResponder")
        } else {
            reassertTerminalSurfaceFocus(reason: "ensureFocus.afterMakeFirstResponder")
        }
    }

    func yieldTerminalSurfaceFocusForForeignResponder(reason: String) {
        surfaceView.desiredFocus = false
        guard let terminalSurface = surfaceView.terminalSurface else { return }
        terminalSurface.setFocus(false)
#if DEBUG
        dlog("focus.surface.yield surface=\(terminalSurface.id.uuidString.prefix(5)) reason=\(reason)")
#endif
        terminalSurface.forceRefresh(reason: "focus.surface.\(reason)")
    }

    private func matchesCurrentTerminalFocusTarget(tabId: UUID, surfaceId: UUID) -> Bool {
        guard let delegate = AppDelegate.shared,
              let tabManager = delegate.tabManagerFor(tabId: tabId) ?? delegate.tabManager,
              tabManager.selectedTabId == tabId,
              let tab = tabManager.tabs.first(where: { $0.id == tabId }),
              let tabIdForSurface = tab.surfaceIdFromPanelId(surfaceId),
              let paneId = tab.bonsplitController.allPaneIds.first(where: { paneId in
                  tab.bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == tabIdForSurface })
              }) else {
            return false
        }

        return tab.bonsplitController.selectedTab(inPane: paneId)?.id == tabIdForSurface &&
            tab.bonsplitController.focusedPaneId == paneId
    }

    /// Suppress the surface view's onFocus callback and ghostty_surface_set_focus during
    /// SwiftUI reparenting (programmatic splits). Call clearSuppressReparentFocus() after layout settles.
    func suppressReparentFocus() {
        surfaceView.suppressingReparentFocus = true
    }

    func isSuppressingReparentFocusForLayoutFollowUp() -> Bool {
        surfaceView.suppressingReparentFocus
    }

    func canClearPendingReparentFocusSuppressionAfterLayoutAttempt() -> Bool {
        // After Workspace has flushed a layout follow-up, the protected reparent
        // turn has passed even if AppKit never tried to focus this old view.
        true
    }

    func clearReparentFocusSuppressionForPointerFocus() {
        guard surfaceView.suppressingReparentFocus else { return }
        surfaceView.suppressingReparentFocus = false
#if DEBUG
        cmuxDebugLog("focus.reparent.pointerClear surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil")")
#endif
    }

    func clearSuppressReparentFocus() {
        surfaceView.suppressingReparentFocus = false
        let hasUsablePortalGeometry: Bool = {
            let size = bounds.size
            return size.width > 1 && size.height > 1
        }()
        let isHiddenForFocus = isHiddenOrHasHiddenAncestor || surfaceView.isHiddenOrHasHiddenAncestor
        let surfaceShort = String(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil")
        let surfaceOwnsFirstResponder = currentTerminalSurfaceOwnsFirstResponder()

        guard surfaceView.desiredFocus || surfaceOwnsFirstResponder else { return }
        guard surfaceView.isVisibleInUI else { return }
        surfaceView.terminalSurface?.recordExternalFocusState(true)
        guard let window = uiWindow, window.isKeyWindow else { return }
        guard !isHiddenForFocus, hasUsablePortalGeometry else {
#if DEBUG
            cmuxDebugLog(
                "focus.reparent.resume.defer surface=\(surfaceShort) " +
                "reason=hidden_or_tiny hidden=\(isHiddenForFocus ? 1 : 0) " +
                "frame=\(String(format: "%.1fx%.1f", bounds.width, bounds.height))"
            )
#endif
            scheduleAutomaticFirstResponderApply(reason: "clearSuppressReparentFocus.hiddenOrTiny")
            return
        }
        if !surfaceOwnsFirstResponder && !isSurfaceViewFirstResponder() {
#if DEBUG
            cmuxDebugLog(
                "focus.reparent.resume.restoreFirstResponder surface=\(surfaceShort) " +
                "firstResponder=\(String(describing: window.firstResponder))"
            )
#endif
            guard requestSurfaceFirstResponder(in: window, reason: "clearSuppressReparentFocus"),
                  isSurfaceViewFirstResponder() else { return }
        }
#if DEBUG
        cmuxDebugLog("focus.reparent.resume surface=\(surfaceShort) firstResponder=\(String(describing: window.firstResponder))")
#endif
        reassertTerminalSurfaceFocus(reason: "clearSuppressReparentFocus", force: true)
    }

    /// Returns true if the terminal's actual Ghostty surface view is (or contains) the window first responder.
    /// This is stricter than checking `hostedView` descendants, since the scroll view can sometimes become
    /// first responder transiently while focus is being applied.
    func isSurfaceViewFirstResponder() -> Bool {
        guard let window = uiWindow, let fr = window.firstResponder as? NSView else { return false }
        return fr === surfaceView || fr.isDescendant(of: surfaceView)
    }

#if DEBUG
    func debugIsSuppressingReparentFocusForTesting() -> Bool {
        surfaceView.suppressingReparentFocus
    }
#endif

    private func currentTerminalSurfaceOwnsFirstResponder() -> Bool {
        guard let window = uiWindow, let firstResponder = window.firstResponder as? NSView else { return false }
        if firstResponder === surfaceView || firstResponder.isDescendant(of: surfaceView) {
            return true
        }
        guard let terminalSurface = surfaceView.terminalSurface else { return false }
        var current: NSView? = firstResponder
        while let view = current {
            if let ghosttyView = view as? GhosttyNSView,
               ghosttyView.terminalSurface === terminalSurface {
                return true
            }
            current = view.superview
        }
        return false
    }

    private func canRequestSurfaceFirstResponder(in window: NSWindow, reason: String) -> Bool {
        guard let terminalSurface = surfaceView.terminalSurface else {
            return true
        }
        let allowed = AppDelegate.shared?.allowsTerminalKeyboardFocus(
            workspaceId: terminalSurface.tabId,
            panelId: terminalSurface.id,
            in: window
        ) ?? true
#if DEBUG
        if !allowed {
            dlog(
                "focus.apply.skip surface=\(terminalSurface.id.uuidString.prefix(5)) " +
                "reason=\(reason).coordinatorRightSidebar"
            )
        }
#endif
        return allowed
    }

    @discardableResult
    private func requestSurfaceFirstResponder(in window: NSWindow, reason: String) -> Bool {
        guard canRequestSurfaceFirstResponder(in: window, reason: reason) else {
            return false
        }
        return window.makeFirstResponder(surfaceView)
    }

    private func scheduleAutomaticFirstResponderApply(reason: String) {
        guard !pendingAutomaticFirstResponderApply else { return }
        pendingAutomaticFirstResponderApply = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingAutomaticFirstResponderApply = false
#if DEBUG
            let surfaceShort = String(self.surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil")
            cmuxDebugLog("find.applyFirstResponder.defer surface=\(surfaceShort) reason=\(reason)")
#endif
            self.applyFirstResponderIfNeeded()
        }
    }

    private func reassertTerminalSurfaceFocus(reason: String, force: Bool = false) {
        guard let terminalSurface = surfaceView.terminalSurface else { return }
        if terminalSurface.surface == nil {
            terminalSurface.requestBackgroundSurfaceStartIfNeeded()
        }
#if DEBUG
        cmuxDebugLog("focus.surface.reassert surface=\(terminalSurface.id.uuidString.prefix(5)) reason=\(reason)")
#endif
        terminalSurface.setFocus(true, force: force)
        refreshSurfaceAfterFocusIfNeeded(reason: reason)
    }

    private func refreshSurfaceAfterFocusIfNeeded(reason: String) {
        guard let terminalSurface = surfaceView.terminalSurface,
              isActive,
              let window = uiWindow,
              window.isKeyWindow,
              surfaceView.isVisibleInUI else { return }

        let now = CACurrentMediaTime()
        if now - lastFocusRefreshAt < 0.05 {
            return
        }
        lastFocusRefreshAt = now
#if DEBUG
        cmuxDebugLog("focus.surface.refresh surface=\(terminalSurface.id.uuidString.prefix(5)) reason=\(reason)")
#endif
        terminalSurface.forceRefresh(reason: "focus.surface.\(reason)")
    }

    private func applyFirstResponderIfNeeded() {
        let hasUsablePortalGeometry: Bool = {
            let size = bounds.size
            return size.width > 1 && size.height > 1
        }()
        let isHiddenForFocus = isHiddenOrHasHiddenAncestor || surfaceView.isHiddenOrHasHiddenAncestor
        let surfaceShort = String(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil")

        guard isActive else { return }
        guard surfaceView.isVisibleInUI else { return }
        guard !isHiddenForFocus, hasUsablePortalGeometry else {
#if DEBUG
            cmuxDebugLog(
                "focus.apply.skip surface=\(surfaceShort) " +
                "reason=hidden_or_tiny hidden=\(isHiddenForFocus ? 1 : 0) frame=\(String(format: "%.1fx%.1f", bounds.width, bounds.height))"
            )
#endif
            return
        }
        guard let window = uiWindow, window.isKeyWindow else { return }
        guard let tabId = surfaceView.tabId,
              let panelId = surfaceView.terminalSurface?.id,
              matchesCurrentTerminalFocusTarget(tabId: tabId, surfaceId: panelId) else {
#if DEBUG
            cmuxDebugLog("focus.apply.skip surface=\(surfaceShort) reason=stale_target")
#endif
            return
        }
        if AppDelegate.shared?.allowsTerminalKeyboardFocus(workspaceId: tabId, panelId: panelId, in: window) == false {
#if DEBUG
            dlog("find.applyFirstResponder SKIP surface=\(surfaceShort) reason=coordinatorRightSidebar")
#endif
            return
        }
        if AppDelegate.shared?.isCommandPaletteEffectivelyVisible(for: window) == true {
#if DEBUG
            cmuxDebugLog("find.applyFirstResponder SKIP surface=\(surfaceShort) reason=commandPaletteVisible")
#endif
            return
        }
        if surfaceView.terminalSurface?.searchState != nil {
            // Find bar is open. Restore focus based on what the user last intended.
            restoreSearchFocus(window: window)
            return
        }
        if let fr = window.firstResponder as? NSView,
           fr === surfaceView || fr.isDescendant(of: surfaceView) {
            reassertTerminalSurfaceFocus(reason: "applyFirstResponder.alreadyFirstResponder")
            return
        }
        // Don't steal focus from a search overlay on another surface in this window.
        if let fr = window.firstResponder, isSearchOverlayOrDescendant(fr) {
#if DEBUG
            cmuxDebugLog("find.applyFirstResponder SKIP surface=\(surfaceShort) reason=searchOverlayFocused")
#endif
            return
        }
        // Don't steal focus from active non-terminal input owners. The terminal surface uses its
        // own GhosttyNSView for input, so NSText and the feed focus host are always foreign focus
        // owners that should survive deferred terminal visibility applies.
        if let firstResponder = window.firstResponder,
           shouldRespectForeignFirstResponder(firstResponder, in: window, isRightSidebarOwner: {
               AppDelegate.shared?.isRightSidebarFocusResponder($0, in: window) == true
           }) {
#if DEBUG
            let reason = firstResponder is NSText ? "textEditorFocused" : "rightSidebarFocused"
            cmuxDebugLog("find.applyFirstResponder SKIP surface=\(surfaceShort) reason=\(reason)")
#endif
            return
        }
#if DEBUG
        cmuxDebugLog("find.applyFirstResponder APPLY surface=\(surfaceShort) prevFirstResponder=\(String(describing: window.firstResponder))")
#endif
        window.makeFirstResponder(surfaceView)
        if isSurfaceViewFirstResponder() {
            reassertTerminalSurfaceFocus(reason: "applyFirstResponder.afterMakeFirstResponder")
        }
    }

    /// Restore focus when window becomes key and the find bar is open.
    /// Respects `searchFocusTarget` so Escape-to-terminal intent is preserved across window switches.
    private func restoreSearchFocus(window: NSWindow) {
        let surfaceShort = String(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil")
        switch searchFocusTarget {
        case .searchField:
            if let firstResponder = window.firstResponder,
               isCurrentSurfaceSearchFieldResponder(firstResponder) {
                surfaceView.terminalSurface?.setFocus(false)
#if DEBUG
                cmuxDebugLog(
                    "find.restoreSearchFocus.skip surface=\(surfaceShort) target=searchField " +
                    "reason=alreadyFocused firstResponder=\(String(describing: firstResponder))"
                )
#endif
                return
            }
            if let firstResponder = window.firstResponder,
               isSearchOverlayOrDescendant(firstResponder),
               !isCurrentSurfaceSearchResponder(firstResponder) {
                surfaceView.terminalSurface?.setFocus(false)
#if DEBUG
                cmuxDebugLog(
                    "find.restoreSearchFocus.skip surface=\(surfaceShort) target=searchField " +
                    "reason=foreignSearchResponder firstResponder=\(String(describing: firstResponder))"
                )
#endif
                return
            }
            if focusMountedSearchFieldIfAvailable(window: window, surfaceShort: surfaceShort) {
                return
            }
            // Explicitly unfocus the terminal so cursor stops blinking immediately.
            // The notification observer also does this, but it runs async when posted from main.
            surfaceView.terminalSurface?.setFocus(false)
            // Post notification — SearchTextFieldRepresentable's Coordinator
            // observes it and calls makeFirstResponder on the native NSTextField.
            if let terminalSurface = surfaceView.terminalSurface {
                NotificationCenter.default.post(name: .ghosttySearchFocus, object: terminalSurface)
            }
#if DEBUG
            cmuxDebugLog(
                "find.restoreSearchFocus surface=\(surfaceShort) target=searchField " +
                "via=notification firstResponder=\(String(describing: window.firstResponder))"
            )
#endif
        case .terminal:
            let result = requestSurfaceFirstResponder(in: window, reason: "restoreSearchFocus.terminal")
#if DEBUG
            cmuxDebugLog(
                "find.restoreSearchFocus surface=\(surfaceShort) target=terminal " +
                "result=\(result ? 1 : 0) firstResponder=\(String(describing: window.firstResponder))"
            )
#endif
        }
    }

    @discardableResult
    private func focusMountedSearchFieldIfAvailable(
        window: NSWindow,
        surfaceShort: String
    ) -> Bool {
        guard canApplyMountedSearchFieldFocusRequest() else {
            return false
        }
        guard let field = mountedSearchFieldIfAvailable() else {
            return false
        }

        let firstResponder = window.firstResponder
        let alreadyFocused = mountedSearchFieldOwnsResponder(firstResponder, field: field)

        surfaceView.terminalSurface?.setFocus(false)

#if DEBUG
        if alreadyFocused {
            cmuxDebugLog(
                "find.restoreSearchFocus.skip surface=\(surfaceShort) target=searchField " +
                "reason=mountedFieldAlreadyFocused firstResponder=\(String(describing: firstResponder))"
            )
        }
#endif
        guard !alreadyFocused else { return true }

        let result = window.makeFirstResponder(field)
        let ownsField = mountedSearchFieldOwnsResponder(window.firstResponder, field: field)

#if DEBUG
        cmuxDebugLog(
            "find.restoreSearchFocus surface=\(surfaceShort) target=searchField " +
            "via=mountedField result=\(result ? 1 : 0) firstResponder=\(String(describing: window.firstResponder))"
        )
#endif

        return ownsField
    }

    func capturePanelFocusIntent(in window: NSWindow?) -> TerminalPanelFocusIntent {
        if surfaceView.terminalSurface?.searchState != nil {
            if let firstResponder = window?.firstResponder as? NSView,
               (firstResponder === surfaceView || firstResponder.isDescendant(of: surfaceView)) {
                return .surface
            }
            if let firstResponder = window?.firstResponder,
               isCurrentSurfaceSearchResponder(firstResponder) {
                return .findField
            }
            if searchFocusTarget == .searchField {
                return .findField
            }
        }
        return .surface
    }

    func preferredPanelFocusIntentForActivation() -> TerminalPanelFocusIntent {
        if surfaceView.terminalSurface?.searchState != nil, searchFocusTarget == .searchField {
            return .findField
        }
        return .surface
    }

    func responderMatchesPreferredKeyboardFocus(_ responder: NSResponder) -> Bool {
        switch preferredPanelFocusIntentForActivation() {
        case .surface:
            guard let view = resolvedKeyboardFocusOwnerView(for: responder) else { return false }
            return view === surfaceView || view.isDescendant(of: surfaceView)

        case .findField:
            return isCurrentSurfaceSearchResponder(responder) &&
                isSearchOverlayOrDescendant(responder)
        case .textBoxInput:
            return false
        }
    }

    func preparePanelFocusIntentForActivation(_ intent: TerminalPanelFocusIntent) {
        switch intent {
        case .surface:
            searchFocusTarget = .terminal
        case .findField:
            guard surfaceView.terminalSurface?.searchState != nil else { return }
            searchFocusTarget = .searchField
        case .textBoxInput:
            searchFocusTarget = .terminal
        }
#if DEBUG
        let targetLabel: String = {
            switch intent {
            case .surface:
                return "terminal"
            case .findField:
                return "searchField"
            case .textBoxInput:
                return "textBoxInput"
            }
        }()
        cmuxDebugLog(
            "find.preparePanelFocusIntent surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
            "target=\(targetLabel)"
        )
#endif
    }

    @discardableResult
    func restorePanelFocusIntent(_ intent: TerminalPanelFocusIntent) -> Bool {
        switch intent {
        case .surface:
            searchFocusTarget = .terminal
            setActive(true)
            applyFirstResponderIfNeeded()
            return true
        case .findField:
            guard let terminalSurface = surfaceView.terminalSurface,
                  terminalSurface.searchState != nil else {
                return false
            }
            searchFocusTarget = .searchField
            setActive(true)
            if let window {
                restoreSearchFocus(window: window)
            } else {
                terminalSurface.setFocus(false)
                NotificationCenter.default.post(name: .ghosttySearchFocus, object: terminalSurface)
            }
#if DEBUG
            cmuxDebugLog(
                "find.restorePanelFocusIntent surface=\(terminalSurface.id.uuidString.prefix(5)) " +
                "target=searchField firstResponder=\(String(describing: window?.firstResponder))"
            )
#endif
            return true
        case .textBoxInput:
            return false
        }
    }

    func ownedPanelFocusIntent(for responder: NSResponder) -> TerminalPanelFocusIntent? {
        if isCurrentSurfaceSearchResponder(responder) {
            return .findField
        }

        guard let view = resolvedKeyboardFocusOwnerView(for: responder) else { return nil }
        if view === surfaceView || view.isDescendant(of: surfaceView) {
            return .surface
        }
        return nil
    }

    @discardableResult
    func yieldPanelFocusIntent(_ intent: TerminalPanelFocusIntent, in window: NSWindow) -> Bool {
        guard intent != .textBoxInput else {
            return false
        }
        guard let firstResponder = window.firstResponder,
              ownedPanelFocusIntent(for: firstResponder) == intent else {
            return false
        }
        if intent == .findField { _ = cmuxRememberFindSelection(in: searchOverlayHostingView) }
        surfaceView.terminalSurface?.setFocus(false)
        resignOwnedFirstResponderIfNeeded(reason: "yieldPanelFocusIntent")
#if DEBUG
        cmuxDebugLog(
            "focus.handoff.yield surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
            "target=\(intent == .findField ? "searchField" : "terminal")"
        )
#endif
        return true
    }

    private func resignOwnedFirstResponderIfNeeded(reason: String) {
        guard let window,
              let firstResponder = window.firstResponder else { return }

        let ownsSurfaceResponder: Bool = {
            guard let view = firstResponder as? NSView else { return false }
            return view === surfaceView || view.isDescendant(of: surfaceView)
        }()

        guard ownsSurfaceResponder || isCurrentSurfaceSearchResponder(firstResponder) else { return }

#if DEBUG
        cmuxDebugLog(
            "focus.surface.resign surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
            "reason=\(reason) firstResponder=\(String(describing: firstResponder))"
        )
#endif
        window.makeFirstResponder(nil)
    }

    /// Check if a responder is inside a search overlay hosting view.
    /// Handles the AppKit field-editor case: when an NSTextField is being edited,
    /// window.firstResponder is the shared NSTextView field editor, not the text field.
    private func isSearchOverlayOrDescendant(_ responder: NSResponder) -> Bool {
        guard let view = resolvedKeyboardFocusOwnerView(for: responder) else { return false }
        var current: NSView? = view
        while let v = current {
            if v is NSHostingView<SurfaceSearchOverlay> { return true }
            let typeName = String(describing: type(of: v))
            if typeName.contains("BrowserSearchOverlay") { return true }
            current = v.superview
        }
        return false
    }

    private func isCurrentSurfaceSearchResponder(_ responder: NSResponder) -> Bool {
        guard let view = resolvedKeyboardFocusOwnerView(for: responder) else { return false }
        return view.isDescendant(of: self)
    }

    private func isCurrentSurfaceSearchFieldResponder(_ responder: NSResponder) -> Bool {
        if let mountedSearchField = mountedSearchFieldIfAvailable(),
           mountedSearchFieldOwnsResponder(responder, field: mountedSearchField) {
            return mountedSearchField.isDescendant(of: self) &&
                isSearchOverlayOrDescendant(mountedSearchField)
        }

        guard let textField = responder as? NSTextField else { return false }
        return textField.isDescendant(of: self) && isSearchOverlayOrDescendant(textField)
    }

#if DEBUG
    struct DebugRenderStats {
        let drawCount: Int
        let lastDrawTime: CFTimeInterval
        let metalDrawableCount: Int
        let metalLastDrawableTime: CFTimeInterval
        let presentCount: Int
        let lastPresentTime: CFTimeInterval
        let layerClass: String
        let layerContentsKey: String
        let inWindow: Bool
        let windowIsKey: Bool
        let windowOcclusionVisible: Bool
        let appIsActive: Bool
        let isActive: Bool
        let desiredFocus: Bool
        let isFirstResponder: Bool
    }

    func debugRenderStats() -> DebugRenderStats {
        let layerClass = surfaceView.layer.map { String(describing: type(of: $0)) } ?? "nil"
        let (metalCount, metalLast) = (surfaceView.layer as? GhosttyMetalLayer)?.debugStats() ?? (0, 0)
        let (drawCount, lastDraw): (Int, CFTimeInterval) = surfaceView.terminalSurface.map { terminalSurface in
            Self.drawStats(for: terminalSurface.id)
        } ?? (0, 0)
        let (presentCount, lastPresent, contentsKey): (Int, CFTimeInterval, String) = surfaceView.terminalSurface.map { terminalSurface in
            let stats = Self.updatePresentStats(surfaceId: terminalSurface.id, layer: surfaceView.layer)
            return (stats.count, stats.last, stats.key)
        } ?? (0, 0, Self.contentsKey(for: surfaceView.layer))
        let inWindow = (window != nil)
        let windowIsKey = window?.isKeyWindow ?? false
        let windowOcclusionVisible = (window?.occlusionState.contains(.visible) ?? false) || (window?.isKeyWindow ?? false)
        let appIsActive = NSApp.isActive
        let fr = window?.firstResponder as? NSView
        let isFirstResponder = fr == surfaceView || (fr?.isDescendant(of: surfaceView) ?? false)
        return DebugRenderStats(
            drawCount: drawCount,
            lastDrawTime: lastDraw,
            metalDrawableCount: metalCount,
            metalLastDrawableTime: metalLast,
            presentCount: presentCount,
            lastPresentTime: lastPresent,
            layerClass: layerClass,
            layerContentsKey: contentsKey,
            inWindow: inWindow,
            windowIsKey: windowIsKey,
            windowOcclusionVisible: windowOcclusionVisible,
            appIsActive: appIsActive,
            isActive: isActive,
            desiredFocus: surfaceView.desiredFocus,
            isFirstResponder: isFirstResponder
        )
    }
#endif

#if DEBUG
    struct DebugFrameSample {
        let sampleCount: Int
        let uniqueQuantized: Int
        let lumaStdDev: Double
        let modeFraction: Double
        let fingerprint: UInt64
        let iosurfaceWidthPx: Int
        let iosurfaceHeightPx: Int
        let expectedWidthPx: Int
        let expectedHeightPx: Int
        let layerClass: String
        let layerContentsGravity: String
        let layerContentsKey: String

        var isProbablyBlank: Bool {
            (lumaStdDev < 3.5 && modeFraction > 0.985) ||
            (uniqueQuantized <= 6 && modeFraction > 0.95)
        }
    }

    /// Create a CGImage from the terminal's IOSurface-backed layer contents.
    ///
    /// This avoids Screen Recording permissions (unlike CGWindowListCreateImage) and is therefore
    /// suitable for debug socket tests running in headless/VM contexts.
    func debugCopyIOSurfaceCGImage() -> CGImage? {
        guard let modelLayer = surfaceView.layer else { return nil }
        let layer = modelLayer.presentation() ?? modelLayer
        guard let contents = layer.contents else { return nil }

        let cf = contents as CFTypeRef
        guard CFGetTypeID(cf) == IOSurfaceGetTypeID() else { return nil }
        let surfaceRef = (contents as! IOSurfaceRef)

        let width = Int(IOSurfaceGetWidth(surfaceRef))
        let height = Int(IOSurfaceGetHeight(surfaceRef))
        let bytesPerRow = Int(IOSurfaceGetBytesPerRow(surfaceRef))
        guard width > 0, height > 0, bytesPerRow > 0 else { return nil }

        IOSurfaceLock(surfaceRef, [], nil)
        defer { IOSurfaceUnlock(surfaceRef, [], nil) }

        let base = IOSurfaceGetBaseAddress(surfaceRef)
        let size = bytesPerRow * height
        let data = Data(bytes: base, count: size)

        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        )

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// Sample the IOSurface backing the terminal layer (if any) to detect a transient blank frame
    /// without using screenshots/screen recording permissions.
    func debugSampleIOSurface(normalizedCrop: CGRect) -> DebugFrameSample? {
        guard let modelLayer = surfaceView.layer else { return nil }
        // Prefer the presentation layer to better match what the user sees on screen.
        let layer = modelLayer.presentation() ?? modelLayer
        let layerClass = String(describing: type(of: layer))
        let layerContentsGravity = layer.contentsGravity.rawValue
        let contentsKey = Self.contentsKey(for: layer)
        let presentationScale = max(1.0, layer.contentsScale)
        let expectedWidthPx = Int((layer.bounds.width * presentationScale).rounded(.toNearestOrAwayFromZero))
        let expectedHeightPx = Int((layer.bounds.height * presentationScale).rounded(.toNearestOrAwayFromZero))

        // Ghostty uses a CoreAnimation layer whose `contents` is an IOSurface-backed object.
        // The concrete layer class is often `IOSurfaceLayer` (private), so avoid referencing it directly.
        guard let anySurface = layer.contents else {
            // Treat "no contents" as a blank frame: this is the visual regression we're guarding.
            return DebugFrameSample(
                sampleCount: 0,
                uniqueQuantized: 0,
                lumaStdDev: 0,
                modeFraction: 1,
                fingerprint: 0,
                iosurfaceWidthPx: 0,
                iosurfaceHeightPx: 0,
                expectedWidthPx: expectedWidthPx,
                expectedHeightPx: expectedHeightPx,
                layerClass: layerClass,
                layerContentsGravity: layerContentsGravity,
                layerContentsKey: contentsKey
            )
        }

        // IOSurfaceLayer.contents is usually an IOSurface, but during mitigation we may
        // temporarily replace contents with a CGImage snapshot to avoid blank flashes.
        // Treat non-IOSurface contents as "non-blank" and avoid unsafe casts.
        let cf = anySurface as CFTypeRef
        guard CFGetTypeID(cf) == IOSurfaceGetTypeID() else {
            var fnv: UInt64 = 1469598103934665603
            for b in contentsKey.utf8 {
                fnv ^= UInt64(b)
                fnv &*= 1099511628211
            }
            return DebugFrameSample(
                sampleCount: 1,
                uniqueQuantized: 1,
                lumaStdDev: 999,
                modeFraction: 0,
                fingerprint: fnv,
                iosurfaceWidthPx: 0,
                iosurfaceHeightPx: 0,
                expectedWidthPx: expectedWidthPx,
                expectedHeightPx: expectedHeightPx,
                layerClass: layerClass,
                layerContentsGravity: layerContentsGravity,
                layerContentsKey: contentsKey
            )
        }

        let surfaceRef = (anySurface as! IOSurfaceRef)

        let width = Int(IOSurfaceGetWidth(surfaceRef))
        let height = Int(IOSurfaceGetHeight(surfaceRef))
        if width <= 0 || height <= 0 { return nil }

        let cropPx = CGRect(
            x: max(0, min(CGFloat(width - 1), normalizedCrop.origin.x * CGFloat(width))),
            y: max(0, min(CGFloat(height - 1), normalizedCrop.origin.y * CGFloat(height))),
            width: max(1, min(CGFloat(width), normalizedCrop.width * CGFloat(width))),
            height: max(1, min(CGFloat(height), normalizedCrop.height * CGFloat(height)))
        ).integral

        let x0 = Int(cropPx.minX)
        let y0 = Int(cropPx.minY)
        let x1 = Int(min(CGFloat(width), cropPx.maxX))
        let y1 = Int(min(CGFloat(height), cropPx.maxY))
        if x1 <= x0 || y1 <= y0 { return nil }

        IOSurfaceLock(surfaceRef, [], nil)
        defer { IOSurfaceUnlock(surfaceRef, [], nil) }

        let base = IOSurfaceGetBaseAddress(surfaceRef)
        let bytesPerRow = IOSurfaceGetBytesPerRow(surfaceRef)
        if bytesPerRow <= 0 { return nil }

        // Assume 4 bytes/pixel BGRA (common for IOSurfaceLayer contents).
        let bytesPerPixel = 4
        let step = 6

        var hist = [UInt16: Int]()
        hist.reserveCapacity(256)

        var lumas = [Double]()
        lumas.reserveCapacity(((x1 - x0) / step) * ((y1 - y0) / step))

        var count = 0
        var fnv: UInt64 = 1469598103934665603

        for y in stride(from: y0, to: y1, by: step) {
            let row = base.advanced(by: y * bytesPerRow)
            for x in stride(from: x0, to: x1, by: step) {
                let p = row.advanced(by: x * bytesPerPixel)
                let b = Double(p.load(fromByteOffset: 0, as: UInt8.self))
                let g = Double(p.load(fromByteOffset: 1, as: UInt8.self))
                let r = Double(p.load(fromByteOffset: 2, as: UInt8.self))
                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                lumas.append(luma)

                let rq = UInt16(UInt8(r) >> 4)
                let gq = UInt16(UInt8(g) >> 4)
                let bq = UInt16(UInt8(b) >> 4)
                let key = (rq << 8) | (gq << 4) | bq
                hist[key, default: 0] += 1
                count += 1

                let lq = UInt8(max(0, min(63, Int(luma / 4.0))))
                fnv ^= UInt64(lq)
                fnv &*= 1099511628211
            }
        }

        guard count > 0 else { return nil }
        let mean = lumas.reduce(0.0, +) / Double(lumas.count)
        let variance = lumas.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / Double(lumas.count)
        let stddev = sqrt(variance)

        let modeCount = hist.values.max() ?? 0
        let modeFrac = Double(modeCount) / Double(count)

        return DebugFrameSample(
            sampleCount: count,
            uniqueQuantized: hist.count,
            lumaStdDev: stddev,
            modeFraction: modeFrac,
            fingerprint: fnv,
            iosurfaceWidthPx: width,
            iosurfaceHeightPx: height,
            expectedWidthPx: expectedWidthPx,
            expectedHeightPx: expectedHeightPx,
            layerClass: layerClass,
            layerContentsGravity: layerContentsGravity,
            layerContentsKey: contentsKey
        )
    }
#endif

    func cancelFocusRequest() {
        // Intentionally no-op (no retry loops).
    }

    private func synchronizeSurfaceView() {
        let visibleRect = scrollView.contentView.documentVisibleRect
        guard !pointApproximatelyEqual(surfaceView.frame.origin, visibleRect.origin) else { return }
#if DEBUG
        logDragGeometryChange(event: "surfaceOrigin", old: surfaceView.frame.origin, new: visibleRect.origin)
#endif
        surfaceView.frame.origin = visibleRect.origin
    }

    /// Match upstream Ghostty behavior: use content area width (excluding non-content
    /// regions such as scrollbar space) when telling libghostty the terminal size.
    @discardableResult
    private func synchronizeCoreSurface() -> Bool {
        let width = max(0, surfaceView.frame.width)
        let height = surfaceView.frame.height
        guard width > 0, height > 0 else { return false }
        return surfaceView.pushTargetSurfaceSize(CGSize(width: width, height: height))
    }

    private func updateNotificationRingPath() {
        updateOverlayRingPath(
            layer: notificationRingLayer,
            bounds: notificationRingOverlayView.bounds,
            inset: NotificationRingMetrics.inset,
            radius: NotificationRingMetrics.cornerRadius
        )
    }

    private func updateFlashPath(style: FlashStyle) {
        let inset: CGFloat
        let radius: CGFloat
        switch style {
        case .navigation, .notification:
            inset = NotificationRingMetrics.inset
            radius = NotificationRingMetrics.cornerRadius
        }
        updateOverlayRingPath(
            layer: flashLayer,
            bounds: flashOverlayView.bounds,
            inset: inset,
            radius: radius
        )
    }

    private func updateFlashAppearance(style: FlashStyle) {
        let presentation = Self.flashPresentation(for: style)
        let strokeColor = presentation.accent.strokeColor
        flashLayer.strokeColor = strokeColor.cgColor
        flashLayer.shadowColor = strokeColor.cgColor
        flashLayer.shadowOpacity = Float(presentation.glowOpacity)
        flashLayer.shadowRadius = presentation.glowRadius
    }

    private func updateOverlayRingPath(
        layer: CAShapeLayer,
        bounds: CGRect,
        inset: CGFloat,
        radius: CGFloat
    ) {
        layer.frame = bounds
        guard bounds.width > inset * 2, bounds.height > inset * 2 else {
            layer.path = nil
            return
        }
        let rect = PanelOverlayRingMetrics.pathRect(in: bounds)
        layer.path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    private func synchronizeScrollView() {
        var didChangeGeometry = false
        let targetDocumentHeight = documentHeight()
        if abs(documentView.frame.height - targetDocumentHeight) > 0.5 {
            documentView.frame.size.height = targetDocumentHeight
            didChangeGeometry = true
        }

        if !isLiveScrolling {
            let cellHeight = surfaceView.cellSize.height
            if cellHeight > 0, let scrollbar = surfaceView.scrollbar {
                let offsetY =
                    CGFloat(scrollbar.total - scrollbar.offset - scrollbar.len) * cellHeight
                let targetOrigin = CGPoint(x: 0, y: offsetY)

                // Check if we're currently at the bottom (with threshold for float drift)
                let currentOrigin = scrollView.contentView.bounds.origin
                let documentHeight = documentView.frame.height
                let viewportHeight = scrollView.contentView.bounds.height
                let distanceFromBottom = documentHeight - currentOrigin.y - viewportHeight
                let isAtBottom = distanceFromBottom <= Self.scrollToBottomThreshold

                // Update userScrolledAwayFromBottom based on current position
                if isAtBottom {
                    userScrolledAwayFromBottom = false
                }

                // Passive bottom packets should not override an explicit scrollback review,
                // but the first scrollbar packet caused by the user's own wheel input should
                // still move the viewport to the requested scrollback position.
                let shouldAutoScroll = !userScrolledAwayFromBottom || allowExplicitScrollbarSync

                if shouldAutoScroll && !pointApproximatelyEqual(currentOrigin, targetOrigin) {
                    scrollView.contentView.scroll(to: targetOrigin)
                    didChangeGeometry = true
                }
                lastSentRow = Int(scrollbar.offset)
            }
        }

        allowExplicitScrollbarSync = false

        if didChangeGeometry {
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func handleScrollChange() {
        synchronizeSurfaceView()
    }

    private func handleLiveScroll() {
        let cellHeight = surfaceView.cellSize.height
        guard cellHeight > 0 else { return }

        let visibleRect = scrollView.contentView.documentVisibleRect
        let documentHeight = documentView.frame.height
        let scrollOffset = documentHeight - visibleRect.origin.y - visibleRect.height

        // Track if user has scrolled away from bottom to review scrollback
        if scrollOffset > Self.scrollToBottomThreshold {
            userScrolledAwayFromBottom = true
        } else if scrollOffset <= 0 {
            userScrolledAwayFromBottom = false
        }

        let row = Int(scrollOffset / cellHeight)

        guard row != lastSentRow else { return }
        lastSentRow = row
        _ = surfaceView.performBindingAction("scroll_to_row:\(row)")
    }

    private func handleScrollbarUpdate(_ notification: Notification) {
        guard let scrollbar = notification.userInfo?[GhosttyNotificationKey.scrollbar] as? GhosttyScrollbar else {
            return
        }
        let wasVisible = scrollView.hasVerticalScroller
        if pendingExplicitWheelScroll {
            userScrolledAwayFromBottom = scrollbar.offset + scrollbar.len < scrollbar.total
            allowExplicitScrollbarSync = true
            pendingExplicitWheelScroll = false
        }
        surfaceView.scrollbar = scrollbar
        let isVisible = shouldShowTerminalScrollBar()
        if wasVisible != isVisible {
            _ = synchronizeGeometryAndContent()
            return
        }
        synchronizeScrollView()
    }

    @discardableResult
    private func synchronizeScrollbarAppearance() -> Bool {
        let shouldShowScrollBar = shouldShowTerminalScrollBar()
        let didChange =
            scrollView.hasVerticalScroller != shouldShowScrollBar ||
            scrollView.autohidesScrollers != false ||
            scrollView.scrollerStyle != .overlay
        scrollView.hasVerticalScroller = shouldShowScrollBar
        // Mirror upstream Ghostty: keep overlay scrollers even when the
        // system preference is legacy so terminal content never sits beneath a
        // permanently reserved scrollbar gutter.
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .overlay
        updateTrackingAreas()
        return didChange
    }

    private func handlePreferredScrollerStyleChange() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.handlePreferredScrollerStyleChange()
            }
            return
        }

        synchronizeScrollbarAppearance()

        // Retile just the scroll view so contentSize reflects the current
        // scroller preference without perturbing hosted terminal geometry.
        scrollView.tile()
        _ = synchronizeCoreSurface()
    }

    private func handleTerminalScrollBarPreferenceChange() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.handleTerminalScrollBarPreferenceChange()
            }
            return
        }

        _ = synchronizeGeometryAndContent()
    }

    private func documentHeight() -> CGFloat {
        let contentHeight = scrollView.contentSize.height
        let cellHeight = surfaceView.cellSize.height
        if cellHeight > 0, let scrollbar = surfaceView.scrollbar {
            let documentGridHeight = CGFloat(scrollbar.total) * cellHeight
            let padding = contentHeight - (CGFloat(scrollbar.len) * cellHeight)
            return documentGridHeight + padding
        }
        return contentHeight
    }

    private func terminalScrollBarAllowedBySettings() -> Bool {
        guard GhosttyApp.shared.scrollbarVisibility() != .never else { return false }
        guard TerminalScrollBarSettings.isVisible() else { return false }
        return true
    }

    private func surfaceHasScrollback() -> Bool? {
        guard let scrollbar = surfaceView.scrollbar else { return nil }
        // Embedded Ghostty exposes alternate-screen TUIs to the wrapper as a
        // viewport with no additional scrollback (`total <= len`). Treat that
        // as the signal to suppress the overlay scrollbar so full-screen apps
        // like nvim/htop do not pin it on top of the rightmost cell column.
        return scrollbar.total > scrollbar.len
    }

    private func shouldShowTerminalScrollBar() -> Bool {
        guard terminalScrollBarAllowedBySettings() else { return false }
        guard let hasScrollback = surfaceHasScrollback() else {
            // Ghostty reports scrollback asynchronously. Until the first packet
            // arrives, keep the scroller visible so restored/reattached
            // surfaces with existing scrollback do not appear broken.
            return true
        }
        return hasScrollback
    }

}
