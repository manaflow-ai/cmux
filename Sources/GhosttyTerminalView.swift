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

@_silgen_name("ghostty_surface_clear_selection")
private func ghostty_surface_clear_selection_compat(_ surface: ghostty_surface_t) -> Bool


func cmuxRuntimeReadClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ state: UnsafeMutableRawPointer?
) -> Bool {
    GhosttyApp.runtimeReadClipboardCallback(userdata, location, state)
}

#if DEBUG
private func cmuxChildExitProbePath() -> String? {
    let env = ProcessInfo.processInfo.environment
    guard env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_SETUP"] == "1",
          let path = env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_PATH"],
          !path.isEmpty else {
        return nil
    }
    return path
}

private func cmuxLoadChildExitProbe(at path: String) -> [String: String] {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
        return [:]
    }
    return object
}

func cmuxWriteChildExitProbe(_ updates: [String: String], increments: [String: Int] = [:]) {
    guard let path = cmuxChildExitProbePath() else { return }
    var payload = cmuxLoadChildExitProbe(at: path)
    for (key, by) in increments {
        let current = Int(payload[key] ?? "") ?? 0
        payload[key] = String(current + by)
    }
    for (key, value) in updates {
        payload[key] = value
    }
    guard let out = try? JSONSerialization.data(withJSONObject: payload) else { return }
    try? out.write(to: URL(fileURLWithPath: path), options: .atomic)
}

private func cmuxScalarHex(_ value: String?) -> String {
    guard let value else { return "" }
    return value.unicodeScalars
        .map { String(format: "%04X", $0.value) }
        .joined(separator: ",")
}
#endif


// MARK: - Ghostty Surface View

class GhosttyNSView: NSView, NSUserInterfaceValidations {
    private static let focusDebugEnabled: Bool = {
        if ProcessInfo.processInfo.environment["CMUX_FOCUS_DEBUG"] == "1" {
            return true
        }
        return UserDefaults.standard.bool(forKey: "cmuxFocusDebug")
    }()
    internal enum DropPlan: Equatable {
        case insertText(String)
        case uploadFiles([URL])
        case reject
    }

    private static let dropTypes: Set<NSPasteboard.PasteboardType> = PasteboardFileURLReader.fileURLPasteboardTypes.union([
        .string,
        .URL,
        .png,
        .tiff,
        NSPasteboard.PasteboardType(UTType.jpeg.identifier),
        NSPasteboard.PasteboardType(UTType.gif.identifier),
        NSPasteboard.PasteboardType(UTType.heic.identifier),
        NSPasteboard.PasteboardType(UTType.heif.identifier)
    ])
    private static let tabTransferPasteboardType = NSPasteboard.PasteboardType("com.splittabbar.tabtransfer")
    private static let sidebarTabReorderPasteboardType = NSPasteboard.PasteboardType("com.cmux.sidebar-tab-reorder")

    private enum WordPathResolutionSource: String {
        case quicklook
        case snapshot
    }

    private struct WordPathResolution {
        let path: String
        let source: WordPathResolutionSource
        let rawToken: String
    }

    private func makeWordPathResolution(
        path: String,
        source: WordPathResolutionSource,
        rawToken: String
    ) -> WordPathResolution {
        WordPathResolution(
            path: path,
            source: source,
            rawToken: rawToken
        )
    }

    static func focusLog(_ message: String) {
        guard focusDebugEnabled else { return }
        AppDelegate.shared?.focusLog.append(message)
        #if DEBUG
        NSLog("[FOCUSDBG] %@", message)
        #endif
    }

    weak var terminalSurface: TerminalSurface?
    var scrollbar: GhosttyScrollbar?
    /// Pending scrollbar value written from the action callback thread;
    /// read and cleared on the main thread by `flushPendingScrollbar()`.
    /// Access is guarded by `_scrollbarLock` because the action callback
    /// fires on Ghostty's I/O thread while the flush runs on main.
    private var _pendingScrollbar: GhosttyScrollbar?
    private var _scrollbarFlushScheduled = false
    private let _scrollbarLock = NSLock()
    private var _renderedFrameFlushScheduled = false
    private let _renderedFrameLock = NSLock()
    var cellSize: CGSize = .zero
    private var lastKnownMousePointInView: NSPoint?

    static func retainRenderedFrameNotifications() -> () -> Void {
        GhosttyRenderedFrameNotificationDemand.retain()
    }

    /// Coalesce high-frequency scrollbar updates into a single main-thread
    /// dispatch.  The action callback (which may fire thousands of times per
    /// second during bulk output like `seq 1 100000`) stores the latest value
    /// and schedules exactly one async flush.
    func enqueueScrollbarUpdate(_ newValue: GhosttyScrollbar) {
        _scrollbarLock.lock()
        defer { _scrollbarLock.unlock() }
        // Store the latest value (always overwrites — only the newest matters).
        _pendingScrollbar = newValue
        let needsSchedule = !_scrollbarFlushScheduled
        if needsSchedule { _scrollbarFlushScheduled = true }

        // If a flush is already scheduled, skip the dispatch — the scheduled
        // block will pick up the latest value.
        guard needsSchedule else { return }
        DispatchQueue.main.async { [weak self] in
            self?.flushPendingScrollbar()
        }
    }

    private func flushPendingScrollbar() {
        _scrollbarLock.lock()
        _scrollbarFlushScheduled = false
        let pending = _pendingScrollbar
        _pendingScrollbar = nil
        _scrollbarLock.unlock()

        guard let pending else { return }
        scrollbar = pending
        finishKeyboardCopyModeViewportJumpCursorSyncIfNeeded(newScrollbar: pending)
        NotificationCenter.default.post(
            name: .ghosttyDidUpdateScrollbar,
            object: self,
            userInfo: [GhosttyNotificationKey.scrollbar: pending]
        )
    }

    private func flushPendingScrollbarIfAvailable() -> Bool {
        _scrollbarLock.lock()
        let hasPending = _pendingScrollbar != nil
        _scrollbarLock.unlock()

        guard hasPending else { return false }
        flushPendingScrollbar()
        return true
    }

    func enqueueRenderedFrameUpdate() {
        guard GhosttyRenderedFrameNotificationDemand.isActive else { return }

        _renderedFrameLock.lock()
        let needsSchedule = !_renderedFrameFlushScheduled
        if needsSchedule {
            _renderedFrameFlushScheduled = true
        }
        _renderedFrameLock.unlock()

        guard needsSchedule else { return }
        DispatchQueue.main.async { [weak self] in
            self?.flushRenderedFrameUpdate()
        }
    }

    private func flushRenderedFrameUpdate() {
        _renderedFrameLock.lock()
        _renderedFrameFlushScheduled = false
        _renderedFrameLock.unlock()

        guard GhosttyRenderedFrameNotificationDemand.isActive else { return }
        NotificationCenter.default.post(
            name: .ghosttyDidRenderFrame,
            object: self
        )
    }

    var desiredFocus: Bool = false
    var suppressingReparentFocus: Bool = false
    var tabId: UUID?
    var onFocus: (() -> Void)?
    var onTriggerFlash: (() -> Void)?
    var backgroundColor: NSColor?
    private var appliedColorScheme: ghostty_color_scheme_e?
    private var lastLoggedSurfaceBackgroundSignature: String?
    private var lastLoggedWindowBackgroundSignature: String?
    private var keySequence: [ghostty_input_trigger_s] = []
    private var keyTables: [String] = []
    fileprivate private(set) var keyboardCopyModeActive = false
    private var wordPathHoverActive = false
    private var keyboardCopyModeConsumedKeyUps: Set<UInt16> = []
    private var imeConsumedKeyUps: Set<UInt16> = []
    private var keyboardCopyModeInputState = TerminalKeyboardCopyModeInputState()
    private var keyboardCopyModeCursor: TerminalKeyboardCopyModeCursor?
    private var keyboardCopyModePendingViewportJumpSync = false
    private var keyboardCopyModePendingViewportJumpScrollbarOffset: UInt64?
    private var keyboardCopyModePendingViewportJumpGeneration = 0
    private var keyboardCopyModePendingViewportJumpFallbackLineDelta: Int?
    private var keyboardCopyModePendingViewportJumpAppliedFallbackLineDelta = 0
    /// Tracks whether the user has explicitly entered visual selection mode (v).
    /// Separate from Ghostty's `has_selection` because non-visual copy mode keeps
    /// the cursor in AppKit overlay state until visual selection starts.
    private var keyboardCopyModeVisualActive = false
    private let keyboardCopyModeCursorOverlayView = GhosttyFlashOverlayView(frame: .zero)
    var isKeyboardCopyModeActive: Bool { keyboardCopyModeActive }
    var currentKeyStateIndicatorText: String? {
        if let name = keyTables.last {
            return terminalKeyTableIndicatorText(name)
        }

        if keyboardCopyModeActive {
            return terminalKeyboardCopyModeIndicatorText
        }

        return nil
    }
#if DEBUG
    private static let keyLatencyProbeEnabled: Bool = {
        if ProcessInfo.processInfo.environment["CMUX_KEY_LATENCY_PROBE"] == "1" {
            return true
        }
        return UserDefaults.standard.bool(forKey: "cmuxKeyLatencyProbe")
    }()
    @MainActor static var debugGhosttySurfaceKeyEventObserver: ((ghostty_input_key_s) -> Void)?
    @MainActor static var debugTextInputEventHandler: ((GhosttyNSView, NSEvent) -> Bool)?
#endif
    private var eventMonitor: Any?
    private var trackingArea: NSTrackingArea?
    private var windowObserver: NSObjectProtocol?
    private var lastScrollEventTime: CFTimeInterval = 0
    private var visibleInUI: Bool = true
    private var pendingSurfaceSize: CGSize?
    private var deferredSurfaceSizeRetryQueued = false
    private var lastDrawableSize: CGSize = .zero
    private var isFindEscapeSuppressionArmed = false
    private var hasPendingLeftMouseRelease = false
#if DEBUG
    private var lastSizeSkipSignature: String?
#endif

    private var hasUsableFocusGeometry: Bool {
        bounds.width > 1 && bounds.height > 1
    }

    static func shouldRequestFirstResponderForMouseFocus(
        focusFollowsMouseEnabled: Bool,
        pressedMouseButtons: Int,
        appIsActive: Bool,
        windowIsKey: Bool,
        alreadyFirstResponder: Bool,
        visibleInUI: Bool,
        hasUsableGeometry: Bool,
        hiddenInHierarchy: Bool
    ) -> Bool {
        guard focusFollowsMouseEnabled else { return false }
        guard pressedMouseButtons == 0 else { return false }
        guard appIsActive, windowIsKey else { return false }
        guard !alreadyFirstResponder else { return false }
        guard visibleInUI, hasUsableGeometry, !hiddenInHierarchy else { return false }
        return true
    }

    // Visibility is used for focus gating. Explicit portal visibility transitions
    // also drive Ghostty occlusion so hidden workspace/split surfaces pause and
    // queue a redraw when they become visible again.
    var isVisibleInUI: Bool { visibleInUI }
    func setVisibleInUI(_ visible: Bool) {
        visibleInUI = visible
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override func makeBackingLayer() -> CALayer {
        let metalLayer = GhosttyMetalLayer()
        metalLayer.setSurfaceView(self)
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.isOpaque = false
        // framebufferOnly=false lets the macOS compositor read the drawable
        // when blending translucent or blurred window layers.  This matches
        // standalone Ghostty's SurfaceView and is required for background-opacity
        // and background-blur to render correctly.
        metalLayer.framebufferOnly = false
        return metalLayer
    }

    private func setup() {
        // GhosttyMetalLayer provides render stats and opt-in frame notifications for
        // input sequencing that needs to wait for terminal redraws.
        wantsLayer = true
        layer?.masksToBounds = true
        setupKeyboardCopyModeCursorOverlay()
        installEventMonitor()
        updateTrackingAreas()
        registerForDraggedTypes(Array(Self.dropTypes))
    }

    private func setupKeyboardCopyModeCursorOverlay() {
        keyboardCopyModeCursorOverlayView.wantsLayer = true
        keyboardCopyModeCursorOverlayView.layer?.backgroundColor = NSColor.controlAccentColor
            .withAlphaComponent(0.45)
            .cgColor
        keyboardCopyModeCursorOverlayView.layer?.borderColor = NSColor.white
            .withAlphaComponent(0.70)
            .cgColor
        keyboardCopyModeCursorOverlayView.layer?.borderWidth = 1
        keyboardCopyModeCursorOverlayView.isHidden = true
        addSubview(keyboardCopyModeCursorOverlayView, positioned: .above, relativeTo: nil)
    }

    private func effectiveBackgroundColor() -> NSColor {
        let base = backgroundColor ?? GhosttyApp.shared.defaultBackgroundColor
        let opacity = GhosttyApp.shared.defaultBackgroundOpacity
        return base.withAlphaComponent(opacity)
    }

    func applySurfaceBackground() {
        let renderingMode = WindowAppearanceSnapshot.terminalRenderingMode(
            usesHostLayerBackground: GhosttyApp.shared.usesHostLayerBackground
        )
        let sharesWindowBackdrop = Workspace.usesWindowRootTerminalBackdrop()
        let usesBonsplitPaneBackdrop = Workspace.usesBonsplitPaneTerminalBackdrop(
            renderingMode: renderingMode,
            sharesWindowBackdrop: sharesWindowBackdrop
        )
        let fillPlan = TerminalSurfaceBackgroundFillPlan.resolve(
            renderingMode: renderingMode,
            surfaceBackgroundColor: backgroundColor,
            defaultBackgroundColor: GhosttyApp.shared.defaultBackgroundColor,
            backgroundOpacity: GhosttyApp.shared.defaultBackgroundOpacity,
            sharesWindowBackdrop: sharesWindowBackdrop,
            usesBonsplitPaneBackdrop: usesBonsplitPaneBackdrop
        )
        let color = fillPlan.hostLayerColor
        if let layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // GhosttySurfaceScrollView owns the panel background fill. Keeping this layer clear
            // avoids stacking multiple identical translucent backgrounds (which looks opaque).
            layer.backgroundColor = NSColor.clear.cgColor
            layer.isOpaque = false
            CATransaction.commit()
        }
        terminalSurface?.hostedView.setBackgroundColor(
            color,
            clearsSharedWindowBackdrop: fillPlan.clearsSharedWindowBackdrop
        )
        if GhosttyApp.shared.backgroundLogEnabled {
            let signature = "\(fillPlan.usesHostLayerFill ? color.hexString() : "transparent-host"):\(String(format: "%.3f", color.alphaComponent)):\(fillPlan.logBackdropLabel)"
            if signature != lastLoggedSurfaceBackgroundSignature {
                lastLoggedSurfaceBackgroundSignature = signature
                let hasOverride = backgroundColor != nil
                let overrideHex = backgroundColor?.hexString() ?? "nil"
                let defaultHex = GhosttyApp.shared.defaultBackgroundColor.hexString()
                GhosttyApp.shared.logBackground(
                    "surface background applied tab=\(tabId?.uuidString ?? "unknown") surface=\(terminalSurface?.id.uuidString ?? "unknown") source=\(fillPlan.logSource(hasSurfaceOverride: hasOverride)) override=\(overrideHex) default=\(defaultHex) sharedWindowBackdrop=\(sharesWindowBackdrop ? 1 : 0) bonsplitPaneBackdrop=\(usesBonsplitPaneBackdrop ? 1 : 0) color=\(color.hexString()) opacity=\(String(format: "%.3f", color.alphaComponent))"
                )
            }
        }
    }

    // Theme/background application is window-local. During cross-window workspace
    // switches (e.g. jump-to-unread), the global active tab manager can lag behind.
    // Prefer the owning window's selected workspace when available.
    static func shouldApplyWindowBackground(
        surfaceTabId: UUID?,
        owningManagerExists: Bool,
        owningSelectedTabId: UUID?,
        activeSelectedTabId: UUID?
    ) -> Bool {
        guard let surfaceTabId else { return true }
        if owningManagerExists {
            guard let owningSelectedTabId else { return true }
            return owningSelectedTabId == surfaceTabId
        }
        if let activeSelectedTabId {
            return activeSelectedTabId == surfaceTabId
        }
        return true
    }

    func applyWindowBackgroundIfActive() {
        guard let window else { return }
        let appDelegate = AppDelegate.shared
        let owningManager = tabId.flatMap { appDelegate?.tabManagerFor(tabId: $0) }
        let owningSelectedTabId = owningManager?.selectedTabId
        let activeSelectedTabId = owningManager == nil ? appDelegate?.tabManager?.selectedTabId : nil
        guard Self.shouldApplyWindowBackground(
            surfaceTabId: tabId,
            owningManagerExists: owningManager != nil,
            owningSelectedTabId: owningSelectedTabId,
            activeSelectedTabId: activeSelectedTabId
        ) else {
            return
        }
        applySurfaceBackground()
        let color = effectiveBackgroundColor()
        let snapshot = WindowAppearanceSnapshot
            .currentFromUserDefaults(app: GhosttyApp.shared)
            .replacingTerminalBackgroundColor(backgroundColor ?? GhosttyApp.shared.defaultBackgroundColor)
        let plan = snapshot.backdropPlan()
        _ = WindowBackdropController.apply(plan: plan, to: window)
        if GhosttyApp.shared.backgroundLogEnabled {
            let signature = "\(plan.hostingPhase.rawValue):\(color.hexString()):\(String(format: "%.3f", color.alphaComponent)):\(GhosttyApp.shared.defaultBackgroundBlur)"
            if signature != lastLoggedWindowBackgroundSignature {
                lastLoggedWindowBackgroundSignature = signature
                let hasOverride = backgroundColor != nil
                let overrideHex = backgroundColor?.hexString() ?? "nil"
                let defaultHex = GhosttyApp.shared.defaultBackgroundColor.hexString()
                let source = hasOverride ? "surfaceOverride" : "defaultBackground"
                GhosttyApp.shared.logBackground(
                    "window background applied tab=\(tabId?.uuidString ?? "unknown") surface=\(terminalSurface?.id.uuidString ?? "unknown") source=\(source) override=\(overrideHex) default=\(defaultHex) phase=\(plan.hostingPhase.rawValue) transparent=\(plan.usesTransparentWindow) color=\(color.hexString()) opacity=\(String(format: "%.3f", color.alphaComponent)) blur=\(GhosttyApp.shared.defaultBackgroundBlur)"
                )
            }
        }
    }

    private func installEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            return self?.localEventHandler(event) ?? event
        }
    }

    private func localEventHandler(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .scrollWheel:
            return localEventScrollWheel(event)
        default:
            return event
        }
    }

    private func localEventScrollWheel(_ event: NSEvent) -> NSEvent? {
        guard let window,
              let eventWindow = event.window,
              window == eventWindow else { return event }

        let location = convert(event.locationInWindow, from: nil)
        guard hitTest(location) == self else { return event }

        Self.focusLog("localEventScrollWheel: window=\(ObjectIdentifier(window)) firstResponder=\(String(describing: window.firstResponder))")
        return event
    }

    func attachSurface(_ surface: TerminalSurface) {
        let isSameSurface = terminalSurface === surface
        let isAlreadyAttached = surface.isAttached(to: self)
        if !isSameSurface {
            appliedColorScheme = nil
        }
        terminalSurface = surface
        tabId = surface.tabId
        if !isAlreadyAttached {
            surface.attachToView(self)
        } else {
            surface.reconcileAttachedWindowIfNeeded(for: self)
        }
        surface.setKeyboardCopyModeActive(keyboardCopyModeActive)
        if !isAlreadyAttached {
            updateSurfaceSize()
        }
        applySurfaceBackground()
        applySurfaceColorScheme(force: !isSameSurface || !isAlreadyAttached)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowObserver {
            NotificationCenter.default.removeObserver(windowObserver)
            self.windowObserver = nil
        }
        // Balance the cursor stack if the view is removed while hover is active
        if wordPathHoverActive {
            wordPathHoverActive = false
            NSCursor.pop()
        }
#if DEBUG
        cmuxDebugLog(
            "surface.view.windowMove surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
            "inWindow=\(window != nil ? 1 : 0) bounds=\(String(format: "%.1fx%.1f", Double(bounds.width), Double(bounds.height))) " +
            "pending=\(String(format: "%.1fx%.1f", Double(pendingSurfaceSize?.width ?? 0), Double(pendingSurfaceSize?.height ?? 0)))"
        )
#endif
        guard let window else { return }

        // Reconcile the already-started runtime with the real window backing context.
        terminalSurface?.attachToView(self)
        if let terminalSurface {
            NotificationCenter.default.post(
                name: .terminalSurfaceHostedViewDidMoveToWindow,
                object: terminalSurface,
                userInfo: [
                    "surfaceId": terminalSurface.id,
                    "workspaceId": terminalSurface.tabId
                ]
            )
        }

        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] notification in
            self?.windowDidChangeScreen(notification)
        }

        if let surface = terminalSurface?.surface,
           let displayID = window.screen?.displayID,
           displayID != 0 {
            ghostty_surface_set_display_id(surface, displayID)
        }

        // Recompute from current bounds after layout. Pending size is only a fallback
        // when we don't have usable bounds (e.g. detached/off-window transitions).
        superview?.layoutSubtreeIfNeeded()
        layoutSubtreeIfNeeded()
        updateSurfaceSize()
        applySurfaceBackground()
        applySurfaceColorScheme(force: true)
        GhosttyApp.shared.synchronizeThemeWithAppearance(
            effectiveAppearance,
            source: "surface.viewDidMoveToWindow"
        )
        applyWindowBackgroundIfActive()
        invalidateTextInputCoordinates()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if GhosttyApp.shared.backgroundLogEnabled {
            let bestMatch = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
            GhosttyApp.shared.logBackground(
                "surface appearance changed tab=\(tabId?.uuidString ?? "nil") surface=\(terminalSurface?.id.uuidString ?? "nil") bestMatch=\(bestMatch?.rawValue ?? "nil")"
            )
        }
        applySurfaceColorScheme()
        GhosttyApp.shared.synchronizeThemeWithAppearance(
            effectiveAppearance,
            source: "surface.viewDidChangeEffectiveAppearance"
        )
    }

    fileprivate func updateOcclusionState() {
        // Intentionally no-op: we don't drive libghostty occlusion from AppKit occlusion state.
        // This avoids transient clears during reparenting and keeps rendering logic minimal.
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }
        updateSurfaceSize()
        invalidateTextInputCoordinates()
    }

    override func layout() {
        super.layout()
        updateSurfaceSize()
        syncKeyboardCopyModeCursorOverlay()
        invalidateTextInputCoordinates()
    }

    override var isOpaque: Bool { false }

    private func resolvedSurfaceSize(preferred size: CGSize?) -> CGSize {
        if let size,
           size.width > 0,
           size.height > 0 {
            return size
        }

        let currentBounds = bounds.size
        if currentBounds.width > 0, currentBounds.height > 0 {
            return currentBounds
        }

        if let pending = pendingSurfaceSize,
           pending.width > 0,
           pending.height > 0 {
            return pending
        }

        return currentBounds
    }

    private static func hasTabDragPasteboardTypes() -> Bool {
        let types = NSPasteboard(name: .drag).types ?? []
        return types.contains(tabTransferPasteboardType) || types.contains(sidebarTabReorderPasteboardType)
    }

    private static func isDragResizeEvent(_ eventType: NSEvent.EventType?) -> Bool {
        switch eventType {
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return true
        default:
            return false
        }
    }

    private static func shouldDeferSurfaceResizeForActiveDrag() -> Bool {
        // The drag pasteboard can retain tab-transfer UTIs briefly after a split command
        // or other layout churn. Only defer terminal resizes while an actual drag event
        // is in flight; otherwise pre-existing panes can stay stuck at their old size.
        // Interactive geometry resize already has an explicit fast path for sidebar and
        // split-divider drags. Do not let stale drag-pasteboard state suppress those updates.
        if TerminalWindowPortalRegistry.isInteractiveGeometryResizeActive {
            return false
        }
        guard hasTabDragPasteboardTypes() else { return false }
        return isDragResizeEvent(NSApp.currentEvent?.type)
    }

    private func activeSurfaceResizeDeferralReason() -> String? {
        if inLiveResize || window?.inLiveResize == true {
            return nil
        }
        return Self.shouldDeferSurfaceResizeForActiveDrag() ? "tabDrag" : nil
    }

    private func scheduleDeferredSurfaceSizeRetryIfNeeded() {
        guard window != nil else { return }
        guard !deferredSurfaceSizeRetryQueued else { return }
        deferredSurfaceSizeRetryQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.deferredSurfaceSizeRetryQueued = false
            _ = self.updateSurfaceSize()
        }
    }

    @discardableResult
    private func updateSurfaceSize(size: CGSize? = nil) -> Bool {
        guard let terminalSurface = terminalSurface else { return false }
        let size = resolvedSurfaceSize(preferred: size)
        guard size.width > 0 && size.height > 0 else {
#if DEBUG
            let signature = "nonPositive-\(Int(size.width))x\(Int(size.height))"
            if lastSizeSkipSignature != signature {
                cmuxDebugLog(
                    "surface.size.defer surface=\(terminalSurface.id.uuidString.prefix(5)) " +
                    "reason=nonPositive size=\(String(format: "%.1fx%.1f", size.width, size.height)) " +
                    "inWindow=\(window != nil ? 1 : 0)"
                )
                lastSizeSkipSignature = signature
            }
#endif
            return false
        }
        pendingSurfaceSize = size
        if let deferralReason = activeSurfaceResizeDeferralReason() {
            scheduleDeferredSurfaceSizeRetryIfNeeded()
#if DEBUG
            let signature = "\(deferralReason)-\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
            if lastSizeSkipSignature != signature {
                cmuxDebugLog(
                    "surface.size.defer surface=\(terminalSurface.id.uuidString.prefix(5)) reason=\(deferralReason) " +
                    "size=\(String(format: "%.1fx%.1f", size.width, size.height)) " +
                    "inWindow=\(window != nil ? 1 : 0)"
                )
                lastSizeSkipSignature = signature
            }
#endif
            return false
        }

        guard let window else {
#if DEBUG
            let signature = "noWindow-\(Int(size.width))x\(Int(size.height))"
            if lastSizeSkipSignature != signature {
                cmuxDebugLog(
                    "surface.size.defer surface=\(terminalSurface.id.uuidString.prefix(5)) reason=noWindow " +
                    "size=\(String(format: "%.1fx%.1f", size.width, size.height))"
                )
                lastSizeSkipSignature = signature
            }
#endif
            return false
        }

        // First principles: derive pixel size from AppKit's backing conversion for the current
        // window/screen. Avoid updating Ghostty while detached from a window.
        let backingSize = convertToBacking(NSRect(origin: .zero, size: size)).size
        guard backingSize.width > 0, backingSize.height > 0 else {
#if DEBUG
            let signature = "zeroBacking-\(Int(backingSize.width))x\(Int(backingSize.height))"
            if lastSizeSkipSignature != signature {
                cmuxDebugLog(
                    "surface.size.defer surface=\(terminalSurface.id.uuidString.prefix(5)) reason=zeroBacking " +
                    "size=\(String(format: "%.1fx%.1f", size.width, size.height)) " +
                    "backing=\(String(format: "%.1fx%.1f", backingSize.width, backingSize.height))"
                )
                lastSizeSkipSignature = signature
            }
#endif
            return false
        }
#if DEBUG
        if lastSizeSkipSignature != nil {
            cmuxDebugLog(
                "surface.size.resume surface=\(terminalSurface.id.uuidString.prefix(5)) " +
                "size=\(String(format: "%.1fx%.1f", size.width, size.height)) " +
                "backing=\(String(format: "%.1fx%.1f", backingSize.width, backingSize.height))"
            )
            lastSizeSkipSignature = nil
        }
#endif
        let xScale = backingSize.width / size.width
        let yScale = backingSize.height / size.height
        let layerScale = max(1.0, window.backingScaleFactor)
        let drawablePixelSize = CGSize(
            width: floor(max(0, backingSize.width)),
            height: floor(max(0, backingSize.height))
        )
        var didChange = false

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let layer, !nearlyEqual(layer.contentsScale, layerScale) {
            didChange = true
        }
        layer?.contentsScale = layerScale
        layer?.masksToBounds = true
        if let metalLayer = layer as? CAMetalLayer {
            if drawablePixelSize != lastDrawableSize || metalLayer.drawableSize != drawablePixelSize {
                if metalLayer.drawableSize != drawablePixelSize {
                    didChange = true
                }
                if metalLayer.drawableSize != drawablePixelSize {
                    metalLayer.drawableSize = drawablePixelSize
                }
                lastDrawableSize = drawablePixelSize
            }
        }
        CATransaction.commit()

        let surfaceSizeChanged = terminalSurface.updateSize(
            width: size.width,
            height: size.height,
            xScale: xScale,
            yScale: yScale,
            layerScale: layerScale,
            backingSize: backingSize
        )
        return didChange || surfaceSizeChanged
    }

    @discardableResult
    func pushTargetSurfaceSize(_ size: CGSize) -> Bool {
        updateSurfaceSize(size: size)
    }

#if DEBUG
    func debugPendingSurfaceSize() -> CGSize? {
        pendingSurfaceSize
    }
#endif

    /// Force a full size reconciliation for the current bounds.
    /// Keep the drawable-size cache intact so redundant refresh paths do not
    /// reallocate Metal drawables when the pixel size is unchanged.
    @discardableResult
    func forceRefreshSurface() -> Bool {
        updateSurfaceSize()
    }

    private func nearlyEqual(_ lhs: CGFloat, _ rhs: CGFloat, epsilon: CGFloat = 0.0001) -> Bool {
        abs(lhs - rhs) <= epsilon
    }

    func expectedPixelSize(for pointsSize: CGSize) -> CGSize {
        let backing = convertToBacking(NSRect(origin: .zero, size: pointsSize)).size
        if backing.width > 0, backing.height > 0 {
            return backing
        }
        let scale = max(1.0, window?.backingScaleFactor ?? layer?.contentsScale ?? 1.0)
        return CGSize(width: pointsSize.width * scale, height: pointsSize.height * scale)
    }

    // Convenience accessor for the ghostty surface
    private var surface: ghostty_surface_t? {
        terminalSurface?.surface
    }

    func applySurfaceColorScheme(
        force: Bool = false,
        preferredColorScheme: GhosttyConfig.ColorSchemePreference? = nil
    ) {
        guard let surface else { return }
        let bestMatch = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        let preferredColorScheme = preferredColorScheme
            ?? GhosttyApp.shared.effectiveTerminalColorSchemePreference
        let scheme = GhosttyApp.ghosttyRuntimeColorScheme(for: preferredColorScheme)
        if !force, appliedColorScheme == scheme {
            if GhosttyApp.shared.backgroundLogEnabled {
                let schemeLabel = scheme == GHOSTTY_COLOR_SCHEME_DARK ? "dark" : "light"
                GhosttyApp.shared.logBackground(
                    "surface color scheme tab=\(tabId?.uuidString ?? "nil") surface=\(terminalSurface?.id.uuidString ?? "nil") bestMatch=\(bestMatch?.rawValue ?? "nil") preferred=\(schemeLabel) scheme=\(schemeLabel) force=\(force) applied=false"
                )
            }
            return
        }
        ghostty_surface_set_color_scheme(surface, scheme)
        appliedColorScheme = scheme
        if GhosttyApp.shared.backgroundLogEnabled {
            let schemeLabel = scheme == GHOSTTY_COLOR_SCHEME_DARK ? "dark" : "light"
            GhosttyApp.shared.logBackground(
                "surface color scheme tab=\(tabId?.uuidString ?? "nil") surface=\(terminalSurface?.id.uuidString ?? "nil") bestMatch=\(bestMatch?.rawValue ?? "nil") preferred=\(schemeLabel) scheme=\(schemeLabel) force=\(force) applied=true"
            )
        }
    }

    @discardableResult
    private func ensureSurfaceReadyForInput() -> ghostty_surface_t? {
        if let surface = surface {
            return surface
        }
        guard window != nil else { return nil }
        terminalSurface?.attachToView(self)
        updateSurfaceSize(size: bounds.size)
        applySurfaceColorScheme(force: true)
        return surface
    }

    private func requestInputRecoveryAfterSurfaceMiss(reason: String) {
        terminalSurface?.requestBackgroundSurfaceStartIfNeeded()
#if DEBUG
        cmuxDebugLog(
            "focus.input_recovery surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
            "reason=\(reason) inWindow=\(window != nil ? 1 : 0)"
        )
#endif
    }

    @discardableResult
    func prepareSurfaceForPaste(reason: String) -> Bool {
        guard ensureSurfaceReadyForInput() != nil else {
            requestInputRecoveryAfterSurfaceMiss(reason: reason)
            return false
        }
        return true
    }

    func performBindingAction(_ action: String) -> Bool {
        guard let surface = surface else { return false }
        return action.withCString { cString in
            ghostty_surface_binding_action(surface, cString, UInt(strlen(cString)))
        }
    }

    @discardableResult
    func toggleKeyboardCopyMode() -> Bool {
        guard surface != nil else { return false }
        setKeyboardCopyModeActive(!keyboardCopyModeActive)
        if !keyboardCopyModeActive, let surface {
            _ = ghostty_surface_clear_selection_compat(surface)
        }
        return true
    }

    private func setKeyboardCopyModeActive(_ active: Bool) {
        keyboardCopyModeInputState.reset()
        keyboardCopyModeVisualActive = false
        keyboardCopyModePendingViewportJumpGeneration += 1
        keyboardCopyModePendingViewportJumpSync = false
        keyboardCopyModePendingViewportJumpScrollbarOffset = nil
        keyboardCopyModePendingViewportJumpFallbackLineDelta = nil
        keyboardCopyModePendingViewportJumpAppliedFallbackLineDelta = 0
        keyboardCopyModeActive = active
        if active, let surface {
            _ = ghostty_surface_clear_selection_compat(surface)
            keyboardCopyModeCursor = keyboardCopyModeInitialCursor(surface: surface)
            syncKeyboardCopyModeCursorOverlay(surface: surface)
        } else {
            keyboardCopyModeCursor = nil
            syncKeyboardCopyModeCursorOverlay()
        }
        terminalSurface?.setKeyboardCopyModeActive(active)
    }

    private func performBindingAction(_ action: String, repeatCount: Int) {
        let count = terminalKeyboardCopyModeClampCount(repeatCount)
        for _ in 0 ..< count {
            _ = performBindingAction(action)
        }
    }

    private func currentKeyboardCopyModeViewportRow(surface: ghostty_surface_t) -> Int {
        let rows = keyboardCopyModeGridMetrics(surface: surface)?.rows
            ?? max(Int(ghostty_surface_size(surface).rows), 1)
        let fallback = rows - 1
        return max(0, min(rows - 1, keyboardCopyModeCursor?.row ?? fallback))
    }

    private struct KeyboardCopyModeGridMetrics {
        let rows: Int
        let columns: Int
        let cellWidth: CGFloat
        let cellHeight: CGFloat
        let xInset: CGFloat
        let yInset: CGFloat
        let viewHeight: CGFloat

        func topOriginRect(for cursor: TerminalKeyboardCopyModeCursor) -> CGRect {
            CGRect(
                x: xInset + (CGFloat(cursor.column) * cellWidth),
                y: yInset + (CGFloat(cursor.row) * cellHeight),
                width: cellWidth,
                height: cellHeight
            )
        }

        func appKitRect(for cursor: TerminalKeyboardCopyModeCursor) -> CGRect {
            let topOrigin = topOriginRect(for: cursor)
            let rawY = viewHeight - topOrigin.maxY
            let maxY = max(viewHeight - topOrigin.height, 0)
            return CGRect(
                x: topOrigin.minX,
                y: min(max(rawY, 0), maxY),
                width: topOrigin.width,
                height: topOrigin.height
            )
        }
    }

    private func keyboardCopyModeGridMetrics(surface: ghostty_surface_t) -> KeyboardCopyModeGridMetrics? {
        let size = ghostty_surface_size(surface)
        let backingRows = max(Int(size.rows), 1)
        let columns = max(Int(size.columns), 1)
        let resolvedCellWidth = cellSize.width > 0 ? cellSize.width : CGFloat(size.cell_width_px)
        let resolvedCellHeight = cellSize.height > 0 ? cellSize.height : CGFloat(size.cell_height_px)
        guard resolvedCellWidth > 0, resolvedCellHeight > 0 else { return nil }

        let rows = terminalKeyboardCopyModeVisibleViewportRows(
            backingRows: backingRows,
            viewHeight: Double(bounds.height),
            cellHeight: Double(resolvedCellHeight)
        )
        let terminalWidth = CGFloat(columns) * resolvedCellWidth
        let terminalHeight = CGFloat(rows) * resolvedCellHeight
        return KeyboardCopyModeGridMetrics(
            rows: rows,
            columns: columns,
            cellWidth: resolvedCellWidth,
            cellHeight: resolvedCellHeight,
            xInset: max(0, (bounds.width - terminalWidth) / 2),
            yInset: max(0, (bounds.height - terminalHeight) / 2),
            viewHeight: bounds.height
        )
    }

    private func keyboardCopyModeInitialCursor(surface: ghostty_surface_t) -> TerminalKeyboardCopyModeCursor {
        guard let metrics = keyboardCopyModeGridMetrics(surface: surface) else {
            return TerminalKeyboardCopyModeCursor(row: 0, column: 0)
        }

        var x: Double = 0
        var y: Double = 0
        var width: Double = 0
        var height: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)

        let row = terminalKeyboardCopyModeInitialViewportRow(
            rows: metrics.rows,
            imePointY: y,
            imeCellHeight: Double(metrics.cellHeight),
            topPadding: Double(metrics.yInset)
        )
        let column = terminalKeyboardCopyModeInitialViewportColumn(
            columns: metrics.columns,
            imePointX: x,
            imeCellWidth: Double(metrics.cellWidth),
            leftPadding: Double(metrics.xInset)
        )
        return TerminalKeyboardCopyModeCursor(row: row, column: column)
    }

    private func syncKeyboardCopyModeCursorOverlay(surface explicitSurface: ghostty_surface_t? = nil) {
        guard keyboardCopyModeActive,
              !keyboardCopyModeVisualActive,
              let surface = explicitSurface ?? self.surface,
              let cursor = keyboardCopyModeCursor,
              let metrics = keyboardCopyModeGridMetrics(surface: surface) else {
            keyboardCopyModeCursorOverlayView.isHidden = true
            return
        }

        let clampedCursor = cursor.clamped(rows: metrics.rows, columns: metrics.columns)
        if clampedCursor != cursor {
            keyboardCopyModeCursor = clampedCursor
        }

        keyboardCopyModeCursorOverlayView.frame = metrics.appKitRect(for: clampedCursor)
        keyboardCopyModeCursorOverlayView.isHidden = false
    }

    private func moveKeyboardCopyModeCursor(
        _ direction: TerminalKeyboardCopyModeSelectionMove,
        count: Int,
        surface: ghostty_surface_t
    ) {
        guard let metrics = keyboardCopyModeGridMetrics(surface: surface) else { return }
        var cursor = keyboardCopyModeCursor ?? keyboardCopyModeInitialCursor(surface: surface)
        let scrollDelta = cursor.move(
            direction,
            count: count,
            rows: metrics.rows,
            columns: metrics.columns
        )
        keyboardCopyModeCursor = cursor
        if scrollDelta != 0 {
            _ = performBindingAction("scroll_page_lines:\(scrollDelta)")
        }
        syncKeyboardCopyModeCursorOverlay(surface: surface)
    }

    private func clampKeyboardCopyModeCursor(surface: ghostty_surface_t) {
        guard let metrics = keyboardCopyModeGridMetrics(surface: surface) else { return }
        let cursor = (keyboardCopyModeCursor ?? keyboardCopyModeInitialCursor(surface: surface))
            .clamped(rows: metrics.rows, columns: metrics.columns)
        keyboardCopyModeCursor = cursor
        syncKeyboardCopyModeCursorOverlay(surface: surface)
    }

    private func beginKeyboardCopyModeViewportJumpCursorSync(fallbackLineDelta: Int? = nil) {
        keyboardCopyModePendingViewportJumpGeneration += 1
        keyboardCopyModePendingViewportJumpSync = true
        keyboardCopyModePendingViewportJumpScrollbarOffset = scrollbar?.offset
        keyboardCopyModePendingViewportJumpFallbackLineDelta = fallbackLineDelta
        keyboardCopyModePendingViewportJumpAppliedFallbackLineDelta = 0
    }

    private func scheduleKeyboardCopyModeViewportJumpCursorSyncFallback() {
        let generation = keyboardCopyModePendingViewportJumpGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            self?.previewKeyboardCopyModeViewportJumpCursorSyncIfNeeded(generation: generation)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(2)) { [weak self] in
            self?.expireKeyboardCopyModeViewportJumpCursorSyncIfNeeded(generation: generation)
        }
    }

    private func previewKeyboardCopyModeViewportJumpCursorSyncIfNeeded(generation: Int) {
        guard keyboardCopyModePendingViewportJumpSync,
              generation == keyboardCopyModePendingViewportJumpGeneration,
              keyboardCopyModeActive,
              let surface else { return }

        if flushPendingScrollbarIfAvailable() {
            return
        }

        if let lineDelta = keyboardCopyModePendingViewportJumpFallbackLineDelta,
           lineDelta != 0,
           keyboardCopyModePendingViewportJumpAppliedFallbackLineDelta == 0 {
            shiftKeyboardCopyModeCursorForViewportScroll(lineDelta: lineDelta, surface: surface)
            keyboardCopyModePendingViewportJumpAppliedFallbackLineDelta = lineDelta
            return
        }

        clampKeyboardCopyModeCursor(surface: surface)
    }

    private func expireKeyboardCopyModeViewportJumpCursorSyncIfNeeded(generation: Int) {
        guard keyboardCopyModePendingViewportJumpSync,
              generation == keyboardCopyModePendingViewportJumpGeneration else { return }

        keyboardCopyModePendingViewportJumpSync = false
        keyboardCopyModePendingViewportJumpScrollbarOffset = nil
        keyboardCopyModePendingViewportJumpFallbackLineDelta = nil
        keyboardCopyModePendingViewportJumpAppliedFallbackLineDelta = 0
    }

    private func finishKeyboardCopyModeViewportJumpCursorSyncIfNeeded(newScrollbar: GhosttyScrollbar? = nil) {
        guard keyboardCopyModePendingViewportJumpSync else { return }
        keyboardCopyModePendingViewportJumpSync = false
        defer {
            keyboardCopyModePendingViewportJumpScrollbarOffset = nil
            keyboardCopyModePendingViewportJumpFallbackLineDelta = nil
            keyboardCopyModePendingViewportJumpAppliedFallbackLineDelta = 0
        }

        guard keyboardCopyModeActive, let surface else { return }
        let resolvedNewOffset = newScrollbar?.offset ?? scrollbar?.offset
        if let previousOffset = keyboardCopyModePendingViewportJumpScrollbarOffset,
           let resolvedNewOffset {
            let lineDelta = keyboardCopyModeViewportLineDelta(
                from: previousOffset,
                to: resolvedNewOffset
            )
            let remainingLineDelta = lineDelta - keyboardCopyModePendingViewportJumpAppliedFallbackLineDelta
            if remainingLineDelta != 0 {
                shiftKeyboardCopyModeCursorForViewportScroll(lineDelta: remainingLineDelta, surface: surface)
                return
            }
        }

        clampKeyboardCopyModeCursor(surface: surface)
    }

    private func keyboardCopyModeViewportLineDelta(from previousOffset: UInt64, to currentOffset: UInt64) -> Int {
        if currentOffset >= previousOffset {
            return Int(clamping: currentOffset - previousOffset)
        }
        return -Int(clamping: previousOffset - currentOffset)
    }

    private func updateKeyboardCopyModeCursorModel(
        _ direction: TerminalKeyboardCopyModeSelectionMove,
        count: Int,
        surface: ghostty_surface_t
    ) {
        guard let metrics = keyboardCopyModeGridMetrics(surface: surface) else { return }
        var cursor = keyboardCopyModeCursor ?? keyboardCopyModeInitialCursor(surface: surface)
        cursor.moveAfterTerminalSelectionAdjustment(
            direction,
            count: count,
            rows: metrics.rows,
            columns: metrics.columns
        )
        keyboardCopyModeCursor = cursor
    }

    private func shiftKeyboardCopyModeCursorForViewportScroll(
        lineDelta: Int,
        surface: ghostty_surface_t
    ) {
        guard lineDelta != 0,
              let metrics = keyboardCopyModeGridMetrics(surface: surface) else { return }
        var cursor = keyboardCopyModeCursor ?? keyboardCopyModeInitialCursor(surface: surface)
        cursor.shiftForViewportScroll(lineDelta: lineDelta, rows: metrics.rows, columns: metrics.columns)
        keyboardCopyModeCursor = cursor
        syncKeyboardCopyModeCursorOverlay(surface: surface)
    }

    private func adjustKeyboardCopyModeSelection(
        _ direction: TerminalKeyboardCopyModeSelectionMove,
        count: Int,
        surface: ghostty_surface_t
    ) {
        let action = "adjust_selection:\(direction.rawValue)"
        let clampedCount = terminalKeyboardCopyModeClampCount(count)
        for _ in 0 ..< clampedCount {
            _ = performBindingAction(action)
            updateKeyboardCopyModeCursorModel(direction, count: 1, surface: surface)
        }
    }

    private func selectKeyboardCopyModeCursorCell(surface: ghostty_surface_t) -> Bool {
        guard let metrics = keyboardCopyModeGridMetrics(surface: surface) else { return false }

        let cursor = (keyboardCopyModeCursor ?? keyboardCopyModeInitialCursor(surface: surface))
            .clamped(rows: metrics.rows, columns: metrics.columns)
        keyboardCopyModeCursor = cursor

        let rect = metrics.topOriginRect(for: cursor)
        let y = min(max(rect.midY, 0), max(bounds.height - 1, 0))
        guard let xRange = terminalKeyboardCopyModeCursorSelectionXRange(
            rectMinX: Double(rect.minX),
            rectMaxX: Double(rect.maxX),
            boundsWidth: Double(bounds.width)
        ) else {
            _ = ghostty_surface_clear_selection_compat(surface)
            return false
        }
        let mods = GHOSTTY_MODS_NONE

        _ = ghostty_surface_clear_selection_compat(surface)
        ghostty_surface_mouse_pos(surface, xRange.startX, Double(y), mods)
        guard ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods) else {
            _ = ghostty_surface_clear_selection_compat(surface)
            return false
        }
        ghostty_surface_mouse_pos(surface, xRange.endX, Double(y), mods)
        let selectedCursorCell = ghostty_surface_has_selection(surface)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
        guard selectedCursorCell else {
            _ = ghostty_surface_clear_selection_compat(surface)
            return false
        }
        return true
    }

    private func copyCurrentViewportLinesToClipboard(
        surface: ghostty_surface_t,
        startRow: Int,
        lineCount: Int
    ) -> Bool {
        guard let metrics = keyboardCopyModeGridMetrics(surface: surface) else { return false }
        let clampedCount = terminalKeyboardCopyModeClampCount(lineCount)
        let rows = metrics.rows
        let targetRow = max(0, min(rows - 1, startRow))
        let endRow = min(rows - 1, targetRow + clampedCount - 1)
        _ = ghostty_surface_clear_selection_compat(surface)

        let yMax = max(bounds.height - 1, 0)

        let startRawY = metrics.topOriginRect(
            for: TerminalKeyboardCopyModeCursor(row: targetRow, column: 0)
        ).midY
        let endRawY = metrics.topOriginRect(
            for: TerminalKeyboardCopyModeCursor(row: endRow, column: max(metrics.columns - 1, 0))
        ).midY
        let startY = max(0, min(startRawY, yMax))
        let endY = max(0, min(endRawY, yMax))
        let xMax = max(bounds.width - 1, 0)
        let startX = min(metrics.xInset + 0.5, xMax)
        let endX = min(metrics.xInset + (CGFloat(metrics.columns) * metrics.cellWidth) - 0.5, xMax)

        let mods = GHOSTTY_MODS_NONE
        ghostty_surface_mouse_pos(surface, Double(startX), Double(startY), mods)
        guard ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods) else {
            return false
        }
        defer {
            _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
        }
        ghostty_surface_mouse_pos(surface, Double(endX), Double(endY), mods)
        guard ghostty_surface_has_selection(surface) else { return false }

        return performBindingAction("copy_to_clipboard")
    }

    private func handleKeyboardCopyModeIfNeeded(_ event: NSEvent, surface: ghostty_surface_t) -> Bool {
        guard keyboardCopyModeActive else { return false }

        if terminalKeyboardCopyModeShouldBypassForShortcut(modifierFlags: event.modifierFlags) {
            keyboardCopyModeInputState.reset()
            return false
        }

        // Use the visual-mode flag instead of raw has_selection; non-visual
        // cursor state is owned by the copy-mode cursor model.
        let hasSelection = keyboardCopyModeVisualActive
        let resolution = terminalKeyboardCopyModeResolve(
            keyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifierFlags: event.modifierFlags,
            hasSelection: hasSelection,
            state: &keyboardCopyModeInputState
        )
        guard case let .perform(action, count) = resolution else {
            return true
        }

        switch action {
        case .exit:
            _ = ghostty_surface_clear_selection_compat(surface)
            setKeyboardCopyModeActive(false)
        case .startSelection:
            if selectKeyboardCopyModeCursorCell(surface: surface) {
                keyboardCopyModeVisualActive = true
                syncKeyboardCopyModeCursorOverlay(surface: surface)
            }
        case .clearSelection:
            keyboardCopyModeVisualActive = false
            _ = ghostty_surface_clear_selection_compat(surface)
            syncKeyboardCopyModeCursorOverlay(surface: surface)
        case .copyAndExit:
            _ = performBindingAction("copy_to_clipboard")
            _ = ghostty_surface_clear_selection_compat(surface)
            setKeyboardCopyModeActive(false)
        case .copyLineAndExit:
            let startRow = currentKeyboardCopyModeViewportRow(surface: surface)
            _ = copyCurrentViewportLinesToClipboard(
                surface: surface,
                startRow: startRow,
                lineCount: count
            )
            _ = ghostty_surface_clear_selection_compat(surface)
            setKeyboardCopyModeActive(false)
        case let .scrollLines(delta):
            let lineDelta = delta * terminalKeyboardCopyModeClampCount(count)
            beginKeyboardCopyModeViewportJumpCursorSync(fallbackLineDelta: lineDelta)
            _ = performBindingAction("scroll_page_lines:\(lineDelta)")
            scheduleKeyboardCopyModeViewportJumpCursorSyncFallback()
        case let .scrollPage(delta):
            let clampedCount = terminalKeyboardCopyModeClampCount(count)
            let rows = keyboardCopyModeGridMetrics(surface: surface)?.rows
                ?? max(Int(ghostty_surface_size(surface).rows), 1)
            beginKeyboardCopyModeViewportJumpCursorSync(fallbackLineDelta: delta * rows * clampedCount)
            performBindingAction(delta > 0 ? "scroll_page_down" : "scroll_page_up", repeatCount: clampedCount)
            scheduleKeyboardCopyModeViewportJumpCursorSyncFallback()
        case let .scrollHalfPage(delta):
            let clampedCount = terminalKeyboardCopyModeClampCount(count)
            let fraction = delta > 0 ? 0.5 : -0.5
            let rows = keyboardCopyModeGridMetrics(surface: surface)?.rows
                ?? max(Int(ghostty_surface_size(surface).rows), 1)
            let linesPerScroll = Int((Double(rows) * 0.5).rounded(.towardZero))
            beginKeyboardCopyModeViewportJumpCursorSync(fallbackLineDelta: delta * linesPerScroll * clampedCount)
            performBindingAction("scroll_page_fractional:\(fraction)", repeatCount: clampedCount)
            scheduleKeyboardCopyModeViewportJumpCursorSyncFallback()
        case .scrollToTop:
            if var cursor = keyboardCopyModeCursor {
                if let metrics = keyboardCopyModeGridMetrics(surface: surface) {
                    _ = cursor.move(.home, count: 1, rows: metrics.rows, columns: metrics.columns)
                } else {
                    cursor.row = 0
                    cursor.column = 0
                }
                keyboardCopyModeCursor = cursor
            }
            _ = performBindingAction("scroll_to_top")
            syncKeyboardCopyModeCursorOverlay(surface: surface)
        case .scrollToBottom:
            if var cursor = keyboardCopyModeCursor {
                if let metrics = keyboardCopyModeGridMetrics(surface: surface) {
                    _ = cursor.move(.end, count: 1, rows: metrics.rows, columns: metrics.columns)
                } else {
                    let size = ghostty_surface_size(surface)
                    cursor.row = max(Int(size.rows) - 1, 0)
                    cursor.column = max(Int(size.columns) - 1, 0)
                }
                keyboardCopyModeCursor = cursor
            }
            _ = performBindingAction("scroll_to_bottom")
            syncKeyboardCopyModeCursorOverlay(surface: surface)
        case let .jumpToPrompt(delta):
            beginKeyboardCopyModeViewportJumpCursorSync()
            _ = performBindingAction("jump_to_prompt:\(delta * count)")
            scheduleKeyboardCopyModeViewportJumpCursorSyncFallback()
        case .startSearch:
            _ = performBindingAction("start_search")
        case .searchNext:
            beginKeyboardCopyModeViewportJumpCursorSync()
            performBindingAction("navigate_search:next", repeatCount: count)
            scheduleKeyboardCopyModeViewportJumpCursorSyncFallback()
        case .searchPrevious:
            beginKeyboardCopyModeViewportJumpCursorSync()
            performBindingAction("navigate_search:previous", repeatCount: count)
            scheduleKeyboardCopyModeViewportJumpCursorSyncFallback()
        case let .adjustSelection(direction):
            if keyboardCopyModeVisualActive {
                adjustKeyboardCopyModeSelection(direction, count: count, surface: surface)
            } else {
                moveKeyboardCopyModeCursor(direction, count: count, surface: surface)
            }
        }
        return true
    }

    // MARK: - Input Handling

    @IBAction func copy(_ sender: Any?) {
        _ = performBindingAction("copy_to_clipboard")
    }

    @IBAction func copyWorkspaceAndSurfaceIdentifiers(_ sender: Any?) {
        guard let terminalSurface else { return }
        let paneId = terminalSurface.owningWorkspace()?.paneId(forPanelId: terminalSurface.id)?.id
        WorkspaceSurfaceIdentifierClipboardText.copy(
            WorkspaceSurfaceIdentifierClipboardText.makeWorkspacePaneSurfaceIdentifiers(
                workspaceId: terminalSurface.tabId,
                paneId: paneId,
                surfaceId: terminalSurface.id,
                includeRefs: true
            )
        )
    }

    @IBAction func copyCurrentSurfaceLink(_ sender: Any?) {
        guard let terminalSurface else { return }
        WorkspaceSurfaceIdentifierClipboardText.copy(
            WorkspaceSurfaceIdentifierClipboardText.makeSurfaceLink(
                workspaceId: terminalSurface.tabId,
                surfaceId: terminalSurface.id
            )
        )
    }

    private func recordDirectAgentHibernationTerminalInput() {
        guard let terminalSurface else { return }
        recordAgentHibernationTerminalInput(
            workspaceId: terminalSurface.tabId,
            panelId: terminalSurface.id
        )
    }

    // MARK: - Clipboard paste

    @IBAction func paste(_ sender: Any?) {
        guard prepareSurfaceForPaste(reason: "paste.missingSurface") else { return }
        recordDirectAgentHibernationTerminalInput()
        _ = performBindingAction("paste_from_clipboard")
    }

    /// Pastes clipboard text as plain text, stripping any rich formatting.
    @IBAction func pasteAsPlainText(_ sender: Any?) {
        guard prepareSurfaceForPaste(reason: "pasteAsPlainText.missingSurface") else { return }
        recordDirectAgentHibernationTerminalInput()
        _ = performBindingAction("paste_from_clipboard")
    }

    private func applyConfiguredMenuShortcut(_ shortcut: StoredShortcut, to item: NSMenuItem) {
        guard let keyEquivalent = shortcut.menuItemKeyEquivalent else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            return
        }

        item.keyEquivalent = keyEquivalent
        item.keyEquivalentModifierMask = shortcut.modifierFlags
    }

    /// Validates whether edit menu items (copy, paste, split) should be enabled.
    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)):
            guard let surface = surface else { return false }
            return ghostty_surface_has_selection(surface)
        case #selector(paste(_:)):
            return GhosttyPasteboardHelper.hasString(for: GHOSTTY_CLIPBOARD_STANDARD)
        case #selector(pasteAsPlainText(_:)):
            return GhosttyPasteboardHelper.hasString(for: GHOSTTY_CLIPBOARD_STANDARD)
        case #selector(splitHorizontally(_:)), #selector(splitVertically(_:)):
            return canSplitCurrentSurface()
        case #selector(copyWorkspaceAndSurfaceIdentifiers(_:)):
            return terminalSurface != nil
        default:
            return true
        }
    }

    // MARK: - Accessibility

    /// Expose the terminal surface as an editable accessibility element.
    /// Voice input tools frequently target AX text areas for text insertion.
    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .textArea
    }

    override func accessibilityHelp() -> String? {
        "Terminal content area"
    }

    override func accessibilityValue() -> Any? {
        // We don't keep a full terminal text snapshot in this layer.
        // Expose selected text when available; otherwise provide an empty value
        // so AX clients still treat this as an editable text area.
        accessibilitySelectedText() ?? ""
    }

    override func setAccessibilityValue(_ value: Any?) {
        let content: String
        switch value {
        case let v as NSAttributedString:
            content = v.string
        case let v as String:
            content = v
        default:
            return
        }

        guard !content.isEmpty else { return }

#if DEBUG
        cmuxDebugLog("ime.ax.setValue len=\(content.count)")
#endif

        let inject = {
            self.withExternalCommittedText {
                self.insertText(content, replacementRange: NSRange(location: NSNotFound, length: 0))
            }
        }
        if Thread.isMainThread {
            inject()
        } else {
            DispatchQueue.main.async(execute: inject)
        }
    }

    private func withExternalCommittedText<T>(_ body: () -> T) -> T {
        externalCommittedTextDepth += 1
        defer { externalCommittedTextDepth -= 1 }
        return body()
    }

    override func accessibilitySelectedTextRange() -> NSRange {
        selectedRange()
    }

    override func accessibilitySelectedText() -> String? {
        guard let snapshot = readSelectionSnapshot() else { return nil }
        return snapshot.string.isEmpty ? nil : snapshot.string
    }

    private func readSelectionSnapshot() -> SelectionSnapshot? {
        guard let surface else { return nil }

        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }

        let selected: String
        if let ptr = text.text, text.text_len > 0 {
            let selectedData = Data(bytes: ptr, count: Int(text.text_len))
            selected = String(decoding: selectedData, as: UTF8.self)
        } else {
            selected = ""
        }

        return SelectionSnapshot(
            range: NSRange(location: Int(text.offset_start), length: Int(text.offset_len)),
            string: selected,
            topLeft: CGPoint(x: text.tl_px_x, y: text.tl_px_y)
        )
    }

    private func visibleDocumentRectInScreenCoordinates() -> NSRect {
        let localRect = visibleRect
        let windowRect = convert(localRect, to: nil)
        guard let window else { return windowRect }
        return window.convertToScreen(windowRect)
    }

    private func invalidateTextInputCoordinates(selectionChanged: Bool = false) {
        guard let inputContext else { return }
        inputContext.invalidateCharacterCoordinates()
        guard selectionChanged else { return }

        // `textInputClientDidUpdateSelection` is absent from the Xcode 16.2 AppKit SDK
        // used by the macOS 14 compatibility lane, so call it dynamically when present.
        let updateSelectionSelector = NSSelectorFromString("textInputClientDidUpdateSelection")
        guard inputContext.responds(to: updateSelectionSelector) else { return }
        _ = inputContext.perform(updateSelectionSelector)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        PaneFirstClickFocusSettings.isEnabled()
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        var shouldApplySurfaceFocus = false
        if result {
            imeConsumedKeyUps.removeAll()
            if let terminalSurface,
               AppDelegate.shared?.allowsTerminalKeyboardFocus(
                   workspaceId: terminalSurface.tabId,
                   panelId: terminalSurface.id,
                   in: window
               ) == false {
                desiredFocus = false
                terminalSurface.recordExternalFocusState(false)
#if DEBUG
                dlog("focus.firstResponder SUPPRESSED (coordinator) surface=\(terminalSurface.id.uuidString.prefix(5))")
#endif
                return result
            }

            // If we become first responder before the ghostty surface exists (e.g. during
            // split/tab creation while the surface is still being created), record the desired focus.
            desiredFocus = true

            // During programmatic splits, SwiftUI reparents the old NSView which triggers
            // becomeFirstResponder. Suppress onFocus + ghostty_surface_set_focus to prevent
            // the old view from stealing focus and creating model/surface divergence.
            if suppressingReparentFocus {
#if DEBUG
                cmuxDebugLog("focus.firstResponder SUPPRESSED (reparent) surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil")")
#endif
                return result
            }

            // Always notify the host app that this pane became the first responder so bonsplit
            // focus/selection can converge. Previously this was gated on `surface != nil`, which
            // allowed a mismatch where AppKit focus moved but the UI focus indicator (bonsplit)
            // stayed behind.
            let hiddenInHierarchy = isHiddenOrHasHiddenAncestor
            if isVisibleInUI && hasUsableFocusGeometry && !hiddenInHierarchy {
                shouldApplySurfaceFocus = true
                onFocus?()
            } else if isVisibleInUI && (!hasUsableFocusGeometry || hiddenInHierarchy) {
#if DEBUG
                cmuxDebugLog(
                    "focus.firstResponder SUPPRESSED (hidden_or_tiny) surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
                    "frame=\(String(format: "%.1fx%.1f", bounds.width, bounds.height)) hidden=\(hiddenInHierarchy ? 1 : 0)"
                )
#endif
            }
        }
        if result, shouldApplySurfaceFocus, let surface = ensureSurfaceReadyForInput() {
            let now = CACurrentMediaTime()
            let deltaMs = (now - lastScrollEventTime) * 1000
            Self.focusLog("becomeFirstResponder: surface=\(terminalSurface?.id.uuidString ?? "nil") deltaSinceScrollMs=\(String(format: "%.2f", deltaMs))")
#if DEBUG
            cmuxDebugLog("focus.firstResponder surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil")")
            if let terminalSurface {
                AppDelegate.shared?.recordJumpUnreadFocusIfExpected(
                    tabId: terminalSurface.tabId,
                    surfaceId: terminalSurface.id
                )
            }
#endif
            if let terminalSurface {
                NotificationCenter.default.post(
                    name: .ghosttyDidBecomeFirstResponderSurface,
                    object: nil,
                    userInfo: [
                        GhosttyNotificationKey.tabId: terminalSurface.tabId,
                        GhosttyNotificationKey.surfaceId: terminalSurface.id,
                    ]
                )
            }
            terminalSurface?.recordExternalFocusState(true)
            ghostty_surface_set_focus(surface, true)

            // Ghostty only restarts its vsync display link on display-id changes while focused.
            // During rapid split close / SwiftUI reparenting, the view can reattach to a window
            // and get its display id set *before* it becomes first responder; in that case, the
            // renderer can remain stuck until some later screen/focus transition. Reassert the
            // display id now that we're focused to ensure the renderer is running.
            if let displayID = window?.screen?.displayID, displayID != 0 {
                ghostty_surface_set_display_id(surface, displayID)
            }
            terminalSurface?.forceRefresh(reason: "focus.firstResponder")
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            imeConsumedKeyUps.removeAll()
            desiredFocus = false
            terminalSurface?.recordExternalFocusState(false)
        }
        if result, let surface = surface {
            let now = CACurrentMediaTime()
            let deltaMs = (now - lastScrollEventTime) * 1000
            Self.focusLog("resignFirstResponder: surface=\(terminalSurface?.id.uuidString ?? "nil") deltaSinceScrollMs=\(String(format: "%.2f", deltaMs))")
            ghostty_surface_set_focus(surface, false)
        }
        return result
    }

    // For NSTextInputClient - accumulates text during key events
    private(set) var keyTextAccumulator: [String]? = nil
    private var markedText = NSMutableAttributedString()
    private var markedSelectedRange = NSRange(location: NSNotFound, length: 0)
    private var lastPerformKeyEvent: TimeInterval?
    private(set) var externalCommittedTextDepth = 0
    var numpadIMECommitDeduplicator = NumpadIMECommitDeduplicator()
    private struct SelectionSnapshot {
        let range: NSRange
        let string: String
        let topLeft: CGPoint
    }

#if DEBUG
    // Test-only accessors for keyTextAccumulator to verify CJK IME composition behavior.
    func setKeyTextAccumulatorForTesting(_ value: [String]?) {
        keyTextAccumulator = value
    }
    var keyTextAccumulatorForTesting: [String]? {
        keyTextAccumulator
    }
    func shouldSuppressShiftSpaceFallbackTextForTesting(event: NSEvent, markedTextBefore: Bool) -> Bool {
        shouldSuppressShiftSpaceFallbackText(event: event, markedTextBefore: markedTextBefore)
    }
    // Test-only IME point override so firstRect behavior can be regression tested.
    private var imePointOverrideForTesting: (x: Double, y: Double, width: Double, height: Double)?
    func setIMEPointForTesting(x: Double, y: Double, width: Double, height: Double) { imePointOverrideForTesting = (x, y, width, height) }
    func clearIMEPointForTesting() { imePointOverrideForTesting = nil }
#endif

#if DEBUG
    private func recordKeyLatency(path: String, event: NSEvent) {
        guard Self.keyLatencyProbeEnabled else { return }
        CmuxTypingTiming.logEventDelay(path: path, event: event)
    }
#endif

    // Prevents NSBeep for unimplemented actions from interpretKeyEvents
    override func doCommand(by selector: Selector) {
        // Intentionally empty - prevents system beep on unhandled key commands
    }

    /// Some third-party voice input apps inject committed text by sending the
    /// responder-chain `insertText:` action (single-argument form).
    /// Route that into our NSTextInputClient path so text lands in the terminal.
    override func insertText(_ insertString: Any) {
        withExternalCommittedText {
            insertText(insertString, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        performKeyEquivalent(with: event, shouldRetryMainMenu: true)
    }

    func performKeyEquivalentAfterMenuMiss(with event: NSEvent) -> Bool {
        performKeyEquivalent(with: event, shouldRetryMainMenu: false)
    }

    private func performKeyEquivalent(with event: NSEvent, shouldRetryMainMenu: Bool) -> Bool {
#if DEBUG
        let typingTimingStart = CmuxTypingTiming.start()
        defer {
            CmuxTypingTiming.logDuration(
                path: "terminal.performKeyEquivalent",
                startedAt: typingTimingStart,
                event: event
            )
        }
#endif
        guard event.type == .keyDown else { return false }
        guard let fr = window?.firstResponder as? NSView,
              fr === self || fr.isDescendant(of: self) else { return false }
        guard let surface = ensureSurfaceReadyForInput() else { return false }

        // Let non-Cmd keys flow to keyDown while IME is composing; Cmd shortcuts still work.
        if hasMarkedText(), !event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) {
            return false
        }

        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])

        // Printable text without Command/Control should stay on the normal keyDown
        // path. AppKit can still route layout-dependent punctuation through
        // performKeyEquivalent first, and probing bindings here can misclassify
        // keys such as ABC-QWERTZ Shift+7 ("/") or Shift+- ("?") as shortcuts.
        if !flags.contains(.command),
           !flags.contains(.control),
           let text = textForKeyEvent(event),
           shouldSendText(text) {
            lastPerformKeyEvent = nil
            return false
        }

#if DEBUG
        recordKeyLatency(path: "performKeyEquivalent", event: event)
#endif

#if DEBUG
        cmuxWriteChildExitProbe(
            [
                "probePerformCharsHex": cmuxScalarHex(event.characters),
                "probePerformCharsIgnoringHex": cmuxScalarHex(event.charactersIgnoringModifiers),
                "probePerformKeyCode": String(event.keyCode),
                "probePerformModsRaw": String(event.modifierFlags.rawValue),
                "probePerformSurfaceId": terminalSurface?.id.uuidString ?? "",
            ],
            increments: ["probePerformKeyEquivalentCount": 1]
        )
#endif

        // Check if this event matches a Ghostty keybinding.
        let bindingFlags: ghostty_binding_flags_e? = {
            var keyEvent = ghosttyKeyEvent(for: event, surface: surface)
            let text = textForKeyEvent(event).flatMap { shouldSendText($0) ? $0 : nil } ?? ""
            var flags = ghostty_binding_flags_e(0)
            let isBinding = text.withCString { ptr in
                keyEvent.text = ptr
                return ghostty_surface_key_is_binding(surface, keyEvent, &flags)
            }
            return isBinding ? flags : nil
        }()

        if let bindingFlags {
            let isConsumed = (bindingFlags.rawValue & GHOSTTY_BINDING_FLAGS_CONSUMED.rawValue) != 0
            let isAll = (bindingFlags.rawValue & GHOSTTY_BINDING_FLAGS_ALL.rawValue) != 0

            // If the binding is consumed and not meant for the menu, allow menu first.
            // Performable bindings (e.g. paste_from_clipboard) also need the menu
            // path so that Edit > Paste handles Cmd+V instead of keyDown double-
            // firing the clipboard request through both interpretKeyEvents and
            // ghostty_surface_key.
            if shouldRetryMainMenu && isConsumed && !isAll && keySequence.isEmpty && keyTables.isEmpty {
                if let menu = NSApp.mainMenu, menu.performKeyEquivalent(with: event) {
                    return true
                }
            }

            // For performable bindings where the menu didn't handle the event,
            // fall through to keyDown so Ghostty can perform the action directly
            // (e.g. paste when no menu item exists).
            keyDown(with: event)
            return true
        }

        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            // Pass Ctrl+Return through verbatim (prevent context menu equivalent).
            guard event.modifierFlags.contains(.control) else { return false }
            equivalent = "\r"

        case "/":
            // Treat Ctrl+/ as Ctrl+_ to avoid the system beep.
            guard event.modifierFlags.contains(.control),
                  event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) else {
                return false
            }
            equivalent = "_"

        default:
            // Ignore synthetic events.
            if event.timestamp == 0 {
                return false
            }

            // Match AppKit key-equivalent routing for menu-style shortcuts (Command-modified).
            // Control-only terminal input (e.g. Ctrl+D) should not participate in redispatch;
            // it must flow through the normal keyDown path exactly once.
            if !event.modifierFlags.contains(.command) {
                lastPerformKeyEvent = nil
                return false
            }

            if !shouldRetryMainMenu { lastPerformKeyEvent = nil; keyDown(with: event); return true }
            if let lastPerformKeyEvent {
                self.lastPerformKeyEvent = nil
                if lastPerformKeyEvent == event.timestamp {
                    equivalent = event.charactersIgnoringModifiers ?? ""
                    break
                }
            }

            lastPerformKeyEvent = event.timestamp; return false
        }

        let finalEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: event.locationInWindow,
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: equivalent,
            charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        )

        if let finalEvent {
            keyDown(with: finalEvent)
            return true
        }

        return false
    }

    override func keyDown(with event: NSEvent) {
#if DEBUG
        let typingTimingStart = CmuxTypingTiming.start()
        let phaseTotalStart = ProcessInfo.processInfo.systemUptime
        var ensureSurfaceMs: Double = 0
        var dismissNotificationMs: Double = 0
        var keyboardCopyModeMs: Double = 0
        var interpretMs: Double = 0
        var syncPreeditMs: Double = 0
        var ghosttySendMs: Double = 0
        defer {
            let totalMs = (ProcessInfo.processInfo.systemUptime - phaseTotalStart) * 1000.0
            CmuxTypingTiming.logBreakdown(
                path: "terminal.keyDown.phase",
                totalMs: totalMs,
                event: event,
                thresholdMs: 1.0,
                parts: [
                    ("ensureSurfaceMs", ensureSurfaceMs),
                    ("dismissNotificationMs", dismissNotificationMs),
                    ("keyboardCopyModeMs", keyboardCopyModeMs),
                    ("interpretMs", interpretMs),
                    ("syncPreeditMs", syncPreeditMs),
                    ("ghosttySendMs", ghosttySendMs),
                ],
                extra: "marked=\(hasMarkedText() ? 1 : 0)"
            )
            CmuxTypingTiming.logDuration(path: "terminal.keyDown", startedAt: typingTimingStart, event: event)
        }
        let ensureSurfaceStart = ProcessInfo.processInfo.systemUptime
#endif
        guard let surface = ensureSurfaceReadyForInput() else {
            requestInputRecoveryAfterSurfaceMiss(reason: "keyDown.missingSurface")
#if DEBUG
            ensureSurfaceMs = (ProcessInfo.processInfo.systemUptime - ensureSurfaceStart) * 1000.0
#endif
            super.keyDown(with: event)
            return
        }
        recordDirectAgentHibernationTerminalInput()
#if DEBUG
        ensureSurfaceMs = (ProcessInfo.processInfo.systemUptime - ensureSurfaceStart) * 1000.0
#endif
        if let mode = RightSidebarMode.modeShortcut(for: event), let window, AppDelegate.shared?.shouldRouteRightSidebarModeShortcut(in: window) == true {
            _ = AppDelegate.shared?.focusRightSidebarInActiveMainWindow(mode: mode, focusFirstItem: true, preferredWindow: window)
            return
        }
        if let terminalSurface {
#if DEBUG
            let dismissNotificationStart = ProcessInfo.processInfo.systemUptime
#endif
            AppDelegate.shared?.tabManager?.dismissNotificationOnTerminalInteraction(
                tabId: terminalSurface.tabId,
                surfaceId: terminalSurface.id
            )
#if DEBUG
            dismissNotificationMs = (ProcessInfo.processInfo.systemUptime - dismissNotificationStart) * 1000.0
#endif
        }
        let flags = ShortcutStroke.normalizedModifierFlags(from: event.modifierFlags)
        if !cmuxFindEventIsPlainEscape(event) { endFindEscapeSuppression() }
        if shouldConsumeSuppressedFindEscape(event) { return }
        if cmuxFindEventIsPlainEscape(event), !hasMarkedText(), let terminalSurface, terminalSurface.searchState != nil {
            terminalSurface.searchState = nil
            beginFindEscapeSuppression(); return
        }
#if DEBUG
        let keyboardCopyModeStart = ProcessInfo.processInfo.systemUptime
#endif
        if handleKeyboardCopyModeIfNeeded(event, surface: surface) {
#if DEBUG
            keyboardCopyModeMs = (ProcessInfo.processInfo.systemUptime - keyboardCopyModeStart) * 1000.0
#endif
            keyboardCopyModeConsumedKeyUps.insert(event.keyCode)
            return
        }
#if DEBUG
        keyboardCopyModeMs = (ProcessInfo.processInfo.systemUptime - keyboardCopyModeStart) * 1000.0
#endif
#if DEBUG
        recordKeyLatency(path: "keyDown", event: event)
#endif

#if DEBUG
        cmuxWriteChildExitProbe(
            [
                "probeKeyDownCharsHex": cmuxScalarHex(event.characters),
                "probeKeyDownCharsIgnoringHex": cmuxScalarHex(event.charactersIgnoringModifiers),
                "probeKeyDownKeyCode": String(event.keyCode),
                "probeKeyDownModsRaw": String(event.modifierFlags.rawValue),
                "probeKeyDownSurfaceId": terminalSurface?.id.uuidString ?? "",
            ],
            increments: ["probeKeyDownCount": 1]
        )
#endif

        // Fast path for control-modified terminal input (for example Ctrl+D).
        //
        // These keys are terminal control input, not text composition, so we bypass
        // AppKit text interpretation and send a single deterministic Ghostty key event.
        // This avoids intermittent drops after rapid split close/reparent transitions.
        if flags.contains(.control) && !flags.contains(.command) && !flags.contains(.option) && !hasMarkedText() {
            terminalSurface?.recordExternalFocusState(true)
            ghostty_surface_set_focus(surface, true)
            var keyEvent = ghostty_input_key_s()
            keyEvent.action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
            keyEvent.keycode = UInt32(event.keyCode)
            keyEvent.mods = modsFromEvent(event)
            keyEvent.consumed_mods = GHOSTTY_MODS_NONE
            keyEvent.composing = false
            keyEvent.unshifted_codepoint = unshiftedCodepointFromEvent(event)

            let text = (event.charactersIgnoringModifiers ?? event.characters ?? "")
            let handled: Bool
            if text.isEmpty {
                keyEvent.text = nil
                #if DEBUG
                let ghosttySendStart = ProcessInfo.processInfo.systemUptime
                handled = sendTimedGhosttyKey(
                    surface,
                    keyEvent,
                    path: "terminal.keyDown.ctrlGhosttySend",
                    event: event
                )
                ghosttySendMs = (ProcessInfo.processInfo.systemUptime - ghosttySendStart) * 1000.0
                #else
                handled = ghostty_surface_key(surface, keyEvent)
                #endif
            } else {
                #if DEBUG
                let sendTimingStart = CmuxTypingTiming.start()
                let ghosttySendStart = ProcessInfo.processInfo.systemUptime
                #endif
                handled = text.withCString { ptr in
                    keyEvent.text = ptr
                    return ghostty_surface_key(surface, keyEvent)
                }
                #if DEBUG
                ghosttySendMs = (ProcessInfo.processInfo.systemUptime - ghosttySendStart) * 1000.0
                CmuxTypingTiming.logDuration(
                    path: "terminal.keyDown.ctrlGhosttySend",
                    startedAt: sendTimingStart,
                    event: event,
                    extra: "handled=\(handled ? 1 : 0)"
                )
                #endif
            }
#if DEBUG
            cmuxDebugLog(
                "key.ctrl path=ghostty surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
                "handled=\(handled ? 1 : 0) keyCode=\(event.keyCode) chars=\(cmuxScalarHex(event.characters)) " +
                "ign=\(cmuxScalarHex(event.charactersIgnoringModifiers)) mods=\(event.modifierFlags.rawValue)"
            )
#endif
            // If Ghostty handled the key (action/encoding), we're done.
            // If not (e.g. `ignore` keybind), fall through to interpretKeyEvents
            // so the IME gets a chance to process this event.
            if handled { return }
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        // Translate mods to respect Ghostty config (e.g., macos-option-as-alt)
        let translationModsGhostty = ghostty_surface_key_translation_mods(surface, modsFromEvent(event))
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            let hasFlag: Bool
            switch flag {
            case .shift:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_SHIFT.rawValue) != 0
            case .control:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_CTRL.rawValue) != 0
            case .option:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_ALT.rawValue) != 0
            case .command:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_SUPER.rawValue) != 0
            default:
                hasFlag = translationMods.contains(flag)
            }
            if hasFlag {
                translationMods.insert(flag)
            } else {
                translationMods.remove(flag)
            }
        }

        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type,
                location: event.locationInWindow,
                modifierFlags: translationMods,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat,
                keyCode: event.keyCode
            ) ?? event
        }
        let textInputEvent = textInputInterpretationEvent(
            original: event,
            translated: translationEvent
        )

        // Set up text accumulator for interpretKeyEvents
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        let markedTextBefore = markedText.length > 0
        let markedStateBefore = (markedText.string, markedSelectedRange)

        // Capture the keyboard layout ID before interpretation so the IME
        // forwarding decision uses the source that saw this key.
        let keyboardIdBefore = KeyboardLayout.id

        // Let the input system handle the event (for IME, dead keys, etc.)
#if DEBUG
        let interpretTimingStart = CmuxTypingTiming.start()
        let interpretPhaseStart = ProcessInfo.processInfo.systemUptime
#endif
#if DEBUG
        if let debugTextInputEventHandler = Self.debugTextInputEventHandler {
            let handled = debugTextInputEventHandler(self, textInputEvent)
            if !handled {
                interpretKeyEvents([textInputEvent])
            }
        } else {
            interpretKeyEvents([textInputEvent])
        }
#else
        interpretKeyEvents([textInputEvent])
#endif
#if DEBUG
        interpretMs = (ProcessInfo.processInfo.systemUptime - interpretPhaseStart) * 1000.0
        CmuxTypingTiming.logDuration(
            path: "terminal.keyDown.interpretKeyEvents",
            startedAt: interpretTimingStart,
            event: event
        )
#endif

        // If the keyboard layout changed, an input method grabbed the event.
        // Sync preedit and return without sending the key to Ghostty.
        if !markedTextBefore, let kbBefore = keyboardIdBefore, kbBefore != KeyboardLayout.id {
            imeConsumedKeyUps.insert(event.keyCode)
#if DEBUG
            let syncPreeditStart = ProcessInfo.processInfo.systemUptime
#endif
            syncPreedit(clearIfNeeded: markedTextBefore)
#if DEBUG
            syncPreeditMs = (ProcessInfo.processInfo.systemUptime - syncPreeditStart) * 1000.0
#endif
            return
        }

        // Sync preedit so Ghostty can render the IME composition overlay.
#if DEBUG
        let syncPreeditStart = ProcessInfo.processInfo.systemUptime
#endif
        syncPreedit(clearIfNeeded: markedTextBefore)
#if DEBUG
        syncPreeditMs = (ProcessInfo.processInfo.systemUptime - syncPreeditStart) * 1000.0
#endif

        let accumulatedText = keyTextAccumulator ?? []
        if shouldSuppressGhosttyKeyForwardingAfterIMEHandling(
            before: markedStateBefore,
            after: (markedText.string, markedSelectedRange),
            accumulatedText: accumulatedText,
            event: textInputEvent,
            inputSourceId: keyboardIdBefore
        ) {
            imeConsumedKeyUps.insert(event.keyCode)
            return
        }

        // A forwarded keyDown owns its keyUp. Clear any stale IME suppression
        // entry left by an earlier suppressed repeat for the same physical key.
        imeConsumedKeyUps.remove(event.keyCode)

        // Build the key event
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = action
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = modsFromEvent(event)
        // Control and Command never contribute to text translation
        keyEvent.consumed_mods = consumedModsFromFlags(translationMods)
        keyEvent.unshifted_codepoint = unshiftedCodepointFromEvent(event)

        // Treat cleared preedit as composing too, so a composing Backspace cancels
        // composition without deleting the preceding terminal input.
        keyEvent.composing = markedText.length > 0 || markedTextBefore

        // Use accumulated text from insertText (for IME), or compute text for key
        if !accumulatedText.isEmpty {
            // Accumulated text comes from insertText (IME composition result).
            // These never have "composing" set to true because these are the
            // result of a composition.
            keyEvent.composing = false
            for text in accumulatedText {
                if shouldSendText(text) {
#if DEBUG
                    let sendTimingStart = CmuxTypingTiming.start()
                    let ghosttySendStart = ProcessInfo.processInfo.systemUptime
#endif
                    text.withCString { ptr in
                        keyEvent.text = ptr
                        #if DEBUG
                        _ = sendTimedGhosttyKey(
                            surface,
                            keyEvent,
                            path: "terminal.keyDown.accumulatedGhosttySend",
                            event: event,
                            extra: "textBytes=\(text.utf8.count)"
                        )
                        #else
                        _ = sendGhosttyKey(surface, keyEvent)
                        #endif
                    }
#if DEBUG
                    ghosttySendMs += (ProcessInfo.processInfo.systemUptime - ghosttySendStart) * 1000.0
                    CmuxTypingTiming.logDuration(
                        path: "terminal.keyDown.accumulatedGhosttySend.total",
                        startedAt: sendTimingStart,
                        event: event,
                        extra: "textBytes=\(text.utf8.count)"
                    )
#endif
                } else {
                    keyEvent.consumed_mods = GHOSTTY_MODS_NONE
                    keyEvent.text = nil
                    #if DEBUG
                    let ghosttySendStart = ProcessInfo.processInfo.systemUptime
                    _ = sendTimedGhosttyKey(
                        surface,
                        keyEvent,
                        path: "terminal.keyDown.accumulatedGhosttySend",
                        event: event
                    )
                    ghosttySendMs += (ProcessInfo.processInfo.systemUptime - ghosttySendStart) * 1000.0
                    #else
                    _ = ghostty_surface_key(surface, keyEvent)
                    #endif
                }
            }

            if shouldSendCommittedIMEConfirmKey(
                event: textInputEvent,
                markedTextBefore: markedTextBefore
            ) {
                keyEvent.consumed_mods = GHOSTTY_MODS_NONE
                keyEvent.text = nil
#if DEBUG
                let ghosttySendStart = ProcessInfo.processInfo.systemUptime
                _ = sendTimedGhosttyKey(
                    surface,
                    keyEvent,
                    path: "terminal.keyDown.accumulatedConfirmGhosttySend",
                    event: event
                )
                ghosttySendMs += (ProcessInfo.processInfo.systemUptime - ghosttySendStart) * 1000.0
#else
                _ = ghostty_surface_key(surface, keyEvent)
#endif
            }
        } else {
            // Get the appropriate text for this key event
            // For control characters, this returns the unmodified character
            // so Ghostty's KeyEncoder can handle ctrl encoding
            let suppressShiftSpaceFallbackText =
                shouldSuppressShiftSpaceFallbackText(
                    event: translationEvent,
                    markedTextBefore: markedTextBefore
                )
            let suppressComposingFallbackText = keyEvent.composing
            if let text = textForKeyEvent(translationEvent) {
                if shouldSendText(text),
                   !suppressShiftSpaceFallbackText,
                   !suppressComposingFallbackText {
                    var handled = false
#if DEBUG
                    let sendTimingStart = CmuxTypingTiming.start()
                    let ghosttySendStart = ProcessInfo.processInfo.systemUptime
#endif
                    text.withCString { ptr in
                        keyEvent.text = ptr
                        #if DEBUG
                        handled = sendTimedGhosttyKey(
                            surface,
                            keyEvent,
                            path: "terminal.keyDown.ghosttySend",
                            event: event,
                            extra: "textBytes=\(text.utf8.count)"
                        )
                        #else
                        handled = sendGhosttyKey(surface, keyEvent)
                        #endif
                    }
                    if handled {
                        notePotentialDeferredNumpadIMECommit(text: text, event: event)
                    }
#if DEBUG
                    ghosttySendMs += (ProcessInfo.processInfo.systemUptime - ghosttySendStart) * 1000.0
                    CmuxTypingTiming.logDuration(
                        path: "terminal.keyDown.ghosttySend.total",
                        startedAt: sendTimingStart,
                        event: event,
                        extra: "handled=\(handled ? 1 : 0) textBytes=\(text.utf8.count)"
                    )
#endif
                } else {
                    keyEvent.consumed_mods = GHOSTTY_MODS_NONE
                    keyEvent.text = nil
                    #if DEBUG
                    let ghosttySendStart = ProcessInfo.processInfo.systemUptime
                    _ = sendTimedGhosttyKey(
                        surface,
                        keyEvent,
                        path: "terminal.keyDown.ghosttySend",
                        event: event
                    )
                    ghosttySendMs += (ProcessInfo.processInfo.systemUptime - ghosttySendStart) * 1000.0
                    #else
                    _ = ghostty_surface_key(surface, keyEvent)
                    #endif
                }
            } else {
                keyEvent.consumed_mods = GHOSTTY_MODS_NONE
                keyEvent.text = nil
                #if DEBUG
                let ghosttySendStart = ProcessInfo.processInfo.systemUptime
                _ = sendTimedGhosttyKey(
                    surface,
                    keyEvent,
                    path: "terminal.keyDown.ghosttySend",
                    event: event
                )
                ghosttySendMs += (ProcessInfo.processInfo.systemUptime - ghosttySendStart) * 1000.0
                #else
                _ = ghostty_surface_key(surface, keyEvent)
                #endif
            }
        }

        // Rendering is driven by Ghostty's wakeups/renderer.
    }

    @discardableResult
    private func sendGhosttyKey(_ surface: ghostty_surface_t, _ keyEvent: ghostty_input_key_s) -> Bool {
#if DEBUG
        Self.debugGhosttySurfaceKeyEventObserver?(keyEvent)
#endif
        return ghostty_surface_key(surface, keyEvent)
    }

#if DEBUG
    @discardableResult
    private func sendTimedGhosttyKey(
        _ surface: ghostty_surface_t,
        _ keyEvent: ghostty_input_key_s,
        path: String,
        event: NSEvent? = nil,
        extra: String? = nil
    ) -> Bool {
        let timingStart = CmuxTypingTiming.start()
        let handled = sendGhosttyKey(surface, keyEvent)
        let baseExtra = "handled=\(handled ? 1 : 0)"
        let mergedExtra: String
        if let extra, !extra.isEmpty {
            mergedExtra = "\(baseExtra) \(extra)"
        } else {
            mergedExtra = baseExtra
        }
        CmuxTypingTiming.logDuration(path: path, startedAt: timingStart, event: event, extra: mergedExtra)
        return handled
    }
#endif

    override func keyUp(with event: NSEvent) {
        guard let surface = ensureSurfaceReadyForInput() else {
            super.keyUp(with: event)
            return
        }
        if event.keyCode != 53 {
            endFindEscapeSuppression()
        }
        if shouldConsumeSuppressedFindEscape(event) {
            endFindEscapeSuppression()
            return
        }
        if event.keyCode == 53 {
            endFindEscapeSuppression()
        }

        if keyboardCopyModeConsumedKeyUps.remove(event.keyCode) != nil {
            return
        }
        if imeConsumedKeyUps.remove(event.keyCode) != nil {
            return
        }

        // Build release events from the same translation path as keyDown so
        // consumers that depend on precise key identity (for example Space
        // hold/release flows) receive consistent metadata.
        var keyEvent = ghosttyKeyEvent(for: event, surface: surface)
        keyEvent.action = GHOSTTY_ACTION_RELEASE
        keyEvent.text = nil
        keyEvent.composing = false
        _ = sendGhosttyKey(surface, keyEvent)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let surface = surface else {
            super.flagsChanged(with: event)
            return
        }

        if !hasMarkedText(),
           let action = cmuxGhosttyModifierActionForFlagsChanged(
            keyCode: event.keyCode,
            modifierFlagsRawValue: event.modifierFlags.rawValue
           ) {
            // `flagsChanged` carries modifier-only state, not textual key input.
            // Building this via `ghosttyKeyEvent(for:surface:)` would fall through
            // to `unshiftedCodepointFromEvent`, which probes AppKit character APIs
            // that are not safe for modifier-only events.
            var keyEvent = ghostty_input_key_s()
            keyEvent.action = action
            keyEvent.keycode = UInt32(event.keyCode)
            keyEvent.mods = modsFromEvent(event)
            keyEvent.consumed_mods = GHOSTTY_MODS_NONE
            keyEvent.text = nil
            keyEvent.composing = false
            keyEvent.unshifted_codepoint = 0
            _ = sendGhosttyKey(surface, keyEvent)
        }

        let selectionActive = ghostty_surface_has_selection(surface)
        let suppressCommandPathHover = event.modifierFlags.contains(.command) && selectionActive
        // Refresh ghostty's mouse position so quicklook_word uses current coordinates
        // when Cmd is pressed while the pointer is stationary.
        let eventPoint = convert(event.locationInWindow, from: nil)
        trackMousePointIfUsable(eventPoint)
        let point = preferredPointerPoint(from: eventPoint) ?? eventPoint
#if DEBUG
        if event.modifierFlags.contains(.command) || selectionActive {
            runtimeDebugLog(
                hypothesisID: "h1",
                name: "flags_changed",
                expected: "selection active should suppress cmd-hover",
                actual: suppressCommandPathHover ? "suppressed" : "forwarded",
                data: [
                    "flags": debugModifierString(event.modifierFlags),
                    "selection_active": selectionActive,
                    "point_x": eventPoint.x,
                    "point_y": eventPoint.y,
                    "resolved_point_x": point.x,
                    "resolved_point_y": point.y
                ]
            )
        }
#endif
        ghostty_surface_mouse_pos(
            surface,
            point.x,
            bounds.height - point.y,
            hoverModsFromFlags(
                event.modifierFlags,
                suppressCommandPathHover: suppressCommandPathHover
            )
        )
        updateWordPathHover(
            at: point,
            cmdHeld: event.modifierFlags.contains(.command),
            suppressPathHover: suppressCommandPathHover
        )
    }

    private func shouldSuppressCommandPathHover(for flags: NSEvent.ModifierFlags) -> Bool {
        guard flags.contains(.command), let surface else { return false }
        return ghostty_surface_has_selection(surface)
    }

    private func hoverModsFromFlags(
        _ flags: NSEvent.ModifierFlags,
        suppressCommandPathHover: Bool
    ) -> ghostty_input_mods_e {
        let effectiveFlags = suppressCommandPathHover ? flags.subtracting(.command) : flags
#if DEBUG
        if suppressCommandPathHover, flags.contains(.command) {
            _ = CmuxUITestCapture.mutateJSONObjectIfConfigured(
                envKey: "CMUX_UI_TEST_CMD_HOVER_DIAGNOSTICS_PATH"
            ) { payload in
                payload["suppressed_command_hover_count"] = (payload["suppressed_command_hover_count"] as? Int ?? 0) + 1
            }
        }
#endif
        return modsFromFlags(effectiveFlags)
    }

    private func modsFromEvent(_ event: NSEvent) -> ghostty_input_mods_e {
        modsFromFlags(event.modifierFlags)
    }

    private func modsFromFlags(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        return ghostty_input_mods_e(rawValue: mods)
    }

    /// Consumed mods are modifiers that were used for text translation.
    /// Control and Command never contribute to text translation, so they
    /// should be excluded from consumed_mods.
    private func consumedModsFromFlags(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        // Only include Shift and Option as potentially consumed
        // Control and Command are never consumed for text translation
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        return ghostty_input_mods_e(rawValue: mods)
    }

    func beginFindEscapeSuppression() {
        isFindEscapeSuppressionArmed = true
    }

    private func endFindEscapeSuppression() {
        isFindEscapeSuppressionArmed = false
    }

    private func shouldConsumeSuppressedFindEscape(_ event: NSEvent) -> Bool {
        isFindEscapeSuppressionArmed && cmuxFindEventIsPlainEscape(event)
    }

    /// Get the characters for a key event with control character handling.
    /// When control is pressed, we get the character without the control modifier
    /// so Ghostty's KeyEncoder can apply its own control character encoding.
    private func textForKeyEvent(_ event: NSEvent) -> String? {
        guard let chars = event.characters, !chars.isEmpty else { return nil }

        if chars.count == 1, let scalar = chars.unicodeScalars.first {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // If we have a single control character, return the character without
            // the control modifier so Ghostty's KeyEncoder can handle it.
            if isControlCharacterScalar(scalar) {
                if flags.contains(.control) {
                    return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
                }

                // Some AppKit key paths can report Shift+` as a bare ESC control
                // character even though the physical key should produce "~".
                if scalar.value == 0x1B,
                   flags == [.shift],
                   event.charactersIgnoringModifiers == "`" {
                    return "~"
                }
            }
            // Private Use Area characters (function keys) should not be sent
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }

        return chars
    }

    /// Get the unshifted codepoint for the key event
    private func unshiftedCodepointFromEvent(_ event: NSEvent) -> UInt32 {
        if let layoutChars = KeyboardLayout.character(forKeyCode: event.keyCode),
           layoutChars.count == 1,
           let layoutScalar = layoutChars.unicodeScalars.first,
           layoutScalar.value >= 0x20,
           !(layoutScalar.value >= 0xF700 && layoutScalar.value <= 0xF8FF) {
            return layoutScalar.value
        }

        guard let chars = (event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? event.characters),
              let scalar = chars.unicodeScalars.first else { return 0 }
        return scalar.value
    }

    /// If AppKit consumed Shift+Space for IME/input-source switching, interpretKeyEvents
    /// can return without insertText and without a detectable layout ID change.
    /// In that case we must not synthesize a literal space fallback.
    private func shouldSuppressShiftSpaceFallbackText(event: NSEvent, markedTextBefore: Bool) -> Bool {
        guard event.keyCode == 49 else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == [.shift] else { return false }
        guard !markedTextBefore, markedText.length == 0 else { return false }
        return true
    }

    private func shouldSendCommittedIMEConfirmKey(event: NSEvent, markedTextBefore: Bool) -> Bool {
        guard markedTextBefore, markedText.length == 0 else { return false }
        guard event.keyCode == 36 || event.keyCode == 76 else { return false }
        // Korean IME: Enter commits the syllable AND executes the command (single step).
        // Japanese/Chinese IME: Enter only confirms the conversion; a second Enter executes.
        // Only send the extra Return key for Korean input sources.
        guard let sourceId = KeyboardLayout.id else { return false }
        return sourceId.range(of: "korean", options: .caseInsensitive) != nil
    }

    private func ghosttyKeyEvent(for event: NSEvent, surface: ghostty_surface_t) -> ghostty_input_key_s {
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = modsFromEvent(event)

        // Translate mods to respect Ghostty config (e.g., macos-option-as-alt).
        let translationModsGhostty = ghostty_surface_key_translation_mods(surface, modsFromEvent(event))
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            let hasFlag: Bool
            switch flag {
            case .shift:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_SHIFT.rawValue) != 0
            case .control:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_CTRL.rawValue) != 0
            case .option:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_ALT.rawValue) != 0
            case .command:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_SUPER.rawValue) != 0
            default:
                hasFlag = translationMods.contains(flag)
            }
            if hasFlag {
                translationMods.insert(flag)
            } else {
                translationMods.remove(flag)
            }
        }

        keyEvent.consumed_mods = consumedModsFromFlags(translationMods)
        keyEvent.text = nil
        keyEvent.composing = false
        keyEvent.unshifted_codepoint = unshiftedCodepointFromEvent(event)
        return keyEvent
    }

    func updateKeySequence(_ action: ghostty_action_key_sequence_s) {
        if action.active {
            keySequence.append(action.trigger)
        } else {
            keySequence.removeAll()
        }
    }

    func updateKeyTable(_ action: ghostty_action_key_table_s) {
        switch action.tag {
        case GHOSTTY_KEY_TABLE_ACTIVATE:
            let namePtr = action.value.activate.name
            let nameLen = Int(action.value.activate.len)
            let name: String
            if let namePtr, nameLen > 0 {
                let data = Data(bytes: namePtr, count: nameLen)
                name = String(data: data, encoding: .utf8) ?? ""
            } else {
                name = ""
            }
            keyTables.append(name)
        case GHOSTTY_KEY_TABLE_DEACTIVATE:
            _ = keyTables.popLast()
        case GHOSTTY_KEY_TABLE_DEACTIVATE_ALL:
            keyTables.removeAll()
        default:
            break
        }

        terminalSurface?.hostedView.syncKeyStateIndicator(text: currentKeyStateIndicatorText)
    }

    // MARK: - Mouse Handling

    #if DEBUG
    private func debugModifierString(_ flags: NSEvent.ModifierFlags) -> String {
        [
            flags.contains(.command) ? "cmd" : nil,
            flags.contains(.shift) ? "shift" : nil,
            flags.contains(.control) ? "ctrl" : nil,
            flags.contains(.option) ? "opt" : nil,
        ].compactMap { $0 }.joined(separator: "+")
    }

    private func runtimeDebugLog(
        hypothesisID: String,
        name: String,
        expected: String? = nil,
        actual: String? = nil,
        data: [String: Any] = [:]
    ) {
        var payload = data
        payload["surface_id"] = terminalSurface?.id.uuidString ?? "nil"
        payload["word_path_hover_active"] = wordPathHoverActive
        CmuxRuntimeDebugCapture.logIfConfigured(
            hypothesisID: hypothesisID,
            source: "GhosttyNSView.\(name)",
            name: name,
            expected: expected,
            actual: actual,
            data: payload
        )
    }

    private func runtimeDebugResolutionPayload(_ resolution: WordPathResolution?) -> [String: Any] {
        guard let resolution else {
            return [
                "resolution_source": "none",
                "resolved_path_basename": "",
                "raw_token": ""
            ]
        }

        return [
            "resolution_source": resolution.source.rawValue,
            "resolved_path_basename": URL(fileURLWithPath: resolution.path).lastPathComponent,
            "raw_token": resolution.rawToken
        ]
    }
    #endif

    private func requestPointerFocusRecovery() {
#if DEBUG
        cmuxDebugLog("focus.pointerDown surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil")")
#endif
        onFocus?()
    }

    override func mouseDown(with event: NSEvent) {
        #if DEBUG
        let debugPoint = convert(event.locationInWindow, from: nil)
        cmuxDebugLog("terminal.mouseDown surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil") mods=[\(debugModifierString(event.modifierFlags))] clickCount=\(event.clickCount) point=(\(String(format: "%.0f", debugPoint.x)),\(String(format: "%.0f", debugPoint.y)))")
        #endif
        // Split reparent/layout churn can suppress the later `becomeFirstResponder -> onFocus`
        // callback. Treat pointer-down as explicit focus intent so clicking a ghost pane still
        // repairs workspace/pane active state before key routing runs.
        if let terminalSurface {
            if terminalSurface.focusPlacement == .rightSidebarDock {
                AppDelegate.shared?.noteRightSidebarKeyboardFocusIntent(mode: .dock, in: window)
            } else {
                AppDelegate.shared?.noteTerminalKeyboardFocusIntent(
                    workspaceId: terminalSurface.tabId,
                    panelId: terminalSurface.id,
                    in: window
                )
            }
            terminalSurface.hostedView.clearReparentFocusSuppressionForPointerFocus()
        }
        requestPointerFocusRecovery()
        window?.makeFirstResponder(self)
        if let terminalSurface {
            AppDelegate.shared?.tabManager?.dismissNotificationOnTerminalInteraction(
                tabId: terminalSurface.tabId,
                surfaceId: terminalSurface.id
            )
        }
        guard let surface = surface else { return }
        let eventPoint = convert(event.locationInWindow, from: nil)
        trackMousePointIfUsable(eventPoint)
        // Only update mouse position on the first click to prevent unwanted cursor
        // movement during double-click selection (issue #1698)
        if event.clickCount == 1 {
            ghostty_surface_mouse_pos(surface, eventPoint.x, bounds.height - eventPoint.y, modsFromEvent(event))
        }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, modsFromEvent(event))
        hasPendingLeftMouseRelease = true
    }

    override func mouseUp(with event: NSEvent) {
        #if DEBUG
        cmuxDebugLog("terminal.mouseUp surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil") mods=[\(debugModifierString(event.modifierFlags))]")
        #endif
        completePendingLeftMouseRelease(with: event)
    }

    @discardableResult
    func forwardPendingLeftMouseDrag(with event: NSEvent) -> Bool {
        guard hasPendingLeftMouseRelease, let surface else { return false }
        let eventPoint = convert(event.locationInWindow, from: nil)
        trackMousePointIfUsable(eventPoint)
        ghostty_surface_mouse_pos(surface, eventPoint.x, bounds.height - eventPoint.y, modsFromEvent(event))
        return true
    }

    @discardableResult
    func completePendingLeftMouseRelease(with event: NSEvent) -> Bool {
        guard hasPendingLeftMouseRelease else { return false }
        hasPendingLeftMouseRelease = false
        guard let surface else { return false }
        let point = convert(event.locationInWindow, from: nil)
        let consumed = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, modsFromEvent(event))
        _ = handleCommandClickRelease(at: point, modifierFlags: event.modifierFlags, ghosttyConsumed: consumed)
        return true
    }

    /// Attempt to open the word under the mouse cursor as a file path, resolved
    /// against the terminal panel's current working directory.
    private func tryOpenWordAsPath(at point: NSPoint? = nil) {
        guard let resolution = resolveWordUnderCursorPath(at: point) else { return }

        #if DEBUG
        cmuxDebugLog("link.wordFallback resolved=\(resolution.path) source=\(resolution.source.rawValue)")
        #endif

        PreferredEditorSettings.open(URL(fileURLWithPath: resolution.path))
    }

    /// Check if the word under the mouse cursor resolves to an existing file/directory
    /// in the terminal panel's CWD. Returns the resolved absolute path, or nil.
    private func resolveWordUnderCursorAsPath(at point: NSPoint? = nil) -> String? {
        resolveWordUnderCursorPath(at: point)?.path
    }

    private func resolveWordUnderCursorPath(at point: NSPoint? = nil) -> WordPathResolution? {
        guard let surface = surface else { return nil }

        guard let termSurface = terminalSurface,
              let workspace = termSurface.owningWorkspace(),
              !workspace.isRemoteTerminalSurface(termSurface.id) else { return nil }

        guard let cwd = resolvedWordPathWorkingDirectory(workspace: workspace, terminalSurface: termSurface) else {
            return nil
        }

        let snapshotPoint = preferredPointerPoint(from: point)
        let pointSnapshotResolution = snapshotPoint.flatMap {
            resolveVisibleWordPath(
                at: $0,
                cwd: cwd,
                workspace: workspace,
                terminalSurface: termSurface
            )
        }

        var text = ghostty_text_s()
        if ghostty_surface_quicklook_word(surface, &text) {
            defer { ghostty_surface_free_text(surface, &text) }
            var quicklookResolution: WordPathResolution?
            if text.text_len > 0, let ptr = text.text {
                let wordData = Data(bytes: ptr, count: Int(text.text_len))
                if let decodedWord = String(bytes: wordData, encoding: .utf8) {
#if DEBUG
                    let resolvedQuicklookWord = cmuxTerminalCmdClickQuicklookOverride(decodedWord)
#else
                    let resolvedQuicklookWord = decodedWord
#endif
                    if let resolvedPath = cmuxResolveQuicklookPath(resolvedQuicklookWord, cwd: cwd) {
                        quicklookResolution = makeWordPathResolution(
                            path: resolvedPath,
                            source: .quicklook,
                            rawToken: resolvedQuicklookWord
                        )
                    }
                }
            }

            var viewportResolution: WordPathResolution?
            if text.offset_len > 0 {
#if DEBUG
                let viewportOffsetStart = cmuxTerminalCmdClickViewportOffsetDelta(Int(text.offset_start))
#else
                let viewportOffsetStart = Int(text.offset_start)
#endif
                viewportResolution = resolveVisibleWordPathFromViewportOffset(
                    viewportOffsetStart,
                    cwd: cwd,
                    workspace: workspace,
                    terminalSurface: termSurface
                )
            }

            if let viewportResolution {
                // The pointer-anchored snapshot is the only source tied directly to the
                // actual click location. Prefer it over quicklook and viewport offsets,
                // which can lag or target a sibling entry in multi-column `ls` output.
                if let pointSnapshotResolution {
                    return pointSnapshotResolution
                }
                return viewportResolution
            }

            if let pointSnapshotResolution {
                return pointSnapshotResolution
            }

            if let quicklookResolution {
                return quicklookResolution
            }
        }

        return pointSnapshotResolution
    }

    #if DEBUG
    private func cmuxTerminalCmdClickQuicklookOverride(_ decodedWord: String) -> String {
        let env = ProcessInfo.processInfo.environment
        guard let override = env["CMUX_UI_TEST_TERMINAL_CMD_CLICK_QUICKLOOK_OVERRIDE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !override.isEmpty else {
            return decodedWord
        }
        return override
    }

    private func cmuxTerminalCmdClickViewportOffsetDelta(_ viewportOffsetStart: Int) -> Int {
        let env = ProcessInfo.processInfo.environment
        guard let delta = env["CMUX_UI_TEST_TERMINAL_CMD_CLICK_VIEWPORT_OFFSET_DELTA"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let parsedDelta = Int(delta) else {
            return viewportOffsetStart
        }
        return max(0, viewportOffsetStart + parsedDelta)
    }
    #endif

    /// Update the pointing-hand cursor when Cmd-hovering over a bare filename
    /// that exists in the terminal's CWD.
    private func updateWordPathHover(
        at point: NSPoint? = nil,
        cmdHeld: Bool,
        suppressPathHover: Bool = false
    ) {
        let hoverWasActive = wordPathHoverActive
        guard cmdHeld, !suppressPathHover else {
            if wordPathHoverActive {
                wordPathHoverActive = false
                NSCursor.pop()
            }
#if DEBUG
            if cmdHeld || suppressPathHover || hoverWasActive {
                runtimeDebugLog(
                    hypothesisID: "h1",
                    name: "hover_update",
                    expected: "cmd-hover off while selection is active",
                    actual: suppressPathHover ? "suppressed" : "inactive",
                    data: [
                        "cmd_held": cmdHeld,
                        "suppress_path_hover": suppressPathHover,
                        "hover_active_before": hoverWasActive,
                        "hover_active_after": wordPathHoverActive
                    ]
                )
            }
#endif
            return
        }

        let resolution = resolveWordUnderCursorPath(at: point)
        if resolution != nil {
            if !wordPathHoverActive {
                wordPathHoverActive = true
                NSCursor.pointingHand.push()
            }
        } else if wordPathHoverActive {
            wordPathHoverActive = false
            NSCursor.pop()
        }
#if DEBUG
        if cmdHeld || hoverWasActive || wordPathHoverActive || resolution != nil {
            var payload: [String: Any] = [
                "cmd_held": cmdHeld,
                "suppress_path_hover": suppressPathHover,
                "hover_active_before": hoverWasActive,
                "hover_active_after": wordPathHoverActive
            ]
            for (key, value) in runtimeDebugResolutionPayload(resolution) {
                payload[key] = value
            }
            runtimeDebugLog(
                hypothesisID: resolution == nil ? "h1" : "h2",
                name: "hover_update",
                expected: "resolved path only when hover should activate",
                actual: wordPathHoverActive ? "hover_active" : "hover_inactive",
                data: payload
            )
        }
#endif
    }

    private func resolvedWordPathWorkingDirectory(
        workspace: Workspace,
        terminalSurface: TerminalSurface
    ) -> String? {
        CommandClickFileOpenRouter.resolveWorkingDirectory(
            workspace: workspace,
            surfaceId: terminalSurface.id
        )
    }

    private func pointIsUsableForWordResolution(_ point: NSPoint) -> Bool {
        bounds.width > 0 &&
        bounds.height > 0 &&
        point.x >= 0 &&
        point.y >= 0 &&
        point.x <= bounds.width &&
        point.y <= bounds.height
    }

    private func trackMousePointIfUsable(_ point: NSPoint) {
        guard pointIsUsableForWordResolution(point) else { return }
        lastKnownMousePointInView = point
    }

    private func preferredPointerPoint(from eventPoint: NSPoint? = nil) -> NSPoint? {
        if let eventPoint, pointIsUsableForWordResolution(eventPoint) {
            lastKnownMousePointInView = eventPoint
            return eventPoint
        }
        if let currentPoint = currentMousePointInView(), pointIsUsableForWordResolution(currentPoint) {
            lastKnownMousePointInView = currentPoint
            return currentPoint
        }
        return lastKnownMousePointInView ?? eventPoint
    }

    private func currentMousePointInView() -> NSPoint? {
        guard let window else { return nil }
        return convert(window.mouseLocationOutsideOfEventStream, from: nil)
    }

    private func resolveVisibleWordPathFromViewportOffset(
        _ viewportOffsetStart: Int,
        cwd: String,
        workspace: Workspace,
        terminalSurface: TerminalSurface
    ) -> WordPathResolution? {
        guard let panel = workspace.terminalPanel(for: terminalSurface.id),
              let surface else {
            return nil
        }

        let size = ghostty_surface_size(surface)
        let rows = max(Int(size.rows), 1)
        let cols = max(Int(size.columns), 1)
        let visibleText = TerminalController.shared.readTerminalTextForSnapshot(
            terminalPanel: panel,
            lineLimit: max(200, rows * 4)
        ) ?? ""
        let visibleLines = cmuxVisibleTerminalLines(from: visibleText, rows: rows)
        let rowOffset = max(0, rows - visibleLines.count)
        let rowFromTop = max(0, min(rows - 1, viewportOffsetStart / cols))
        let visibleRow = rowFromTop - rowOffset
        guard visibleRow >= 0, visibleRow < visibleLines.count else { return nil }

        let column = max(0, min(cols - 1, viewportOffsetStart % cols))
        guard let resolution = cmuxResolveVisibleLinePath(
            visibleLines[visibleRow],
            column: column,
            cwd: cwd
        ) else {
            return nil
        }

        return makeWordPathResolution(
            path: resolution.path,
            source: .snapshot,
            rawToken: resolution.rawToken
        )
    }

    private func resolveVisibleWordPath(
        at point: NSPoint,
        cwd: String,
        workspace: Workspace,
        terminalSurface: TerminalSurface
    ) -> WordPathResolution? {
        guard let panel = workspace.terminalPanel(for: terminalSurface.id),
              let surface else {
            return nil
        }

        let size = ghostty_surface_size(surface)
        let rows = max(Int(size.rows), 1)
        let cols = max(Int(size.columns), 1)
        let resolvedCellWidth = cellSize.width > 0 ? cellSize.width : CGFloat(size.cell_width_px)
        let resolvedCellHeight = cellSize.height > 0 ? cellSize.height : CGFloat(size.cell_height_px)
        guard resolvedCellWidth > 0, resolvedCellHeight > 0 else { return nil }

        let visibleText = TerminalController.shared.readTerminalTextForSnapshot(
            terminalPanel: panel,
            lineLimit: max(200, rows * 4)
        ) ?? ""
        let visibleLines = cmuxVisibleTerminalLines(from: visibleText, rows: rows)
        let rowOffset = max(0, rows - visibleLines.count)
        let xInset = max(0, (bounds.width - (CGFloat(cols) * resolvedCellWidth)) / 2)
        let yInset = max(0, (bounds.height - (CGFloat(rows) * resolvedCellHeight)) / 2)

        let yFromTop = bounds.height - point.y
        let rowFromTop = max(0, min(rows - 1, Int((yFromTop - yInset) / resolvedCellHeight)))
        let visibleRow = rowFromTop - rowOffset
        guard visibleRow >= 0, visibleRow < visibleLines.count else { return nil }

        let column = max(0, min(cols - 1, Int((point.x - xInset) / resolvedCellWidth)))
        guard let resolution = cmuxResolveVisibleLinePath(
            visibleLines[visibleRow],
            column: column,
            cwd: cwd
        ) else {
            return nil
        }

        return makeWordPathResolution(
            path: resolution.path,
            source: .snapshot,
            rawToken: resolution.rawToken
        )
    }

    @discardableResult
    private func handleCommandClickRelease(
        at point: NSPoint,
        modifierFlags: NSEvent.ModifierFlags,
        ghosttyConsumed: Bool
    ) -> WordPathResolution? {
        guard let surface else { return nil }
        let suppressCommandPathHover = shouldSuppressCommandPathHover(for: modifierFlags)
        let cmdHeld = modifierFlags.contains(.command)
        let resolvedPoint = preferredPointerPoint(from: point)
        guard cmdHeld, !suppressCommandPathHover else {
#if DEBUG
            if cmdHeld || suppressCommandPathHover {
                runtimeDebugLog(
                    hypothesisID: "h1",
                    name: "command_click_release",
                    expected: "cmd-click fallback only when selection is inactive",
                    actual: suppressCommandPathHover ? "suppressed" : "not_cmd_click",
                    data: [
                        "flags": debugModifierString(modifierFlags),
                        "ghostty_consumed": ghosttyConsumed,
                        "point_x": point.x,
                        "point_y": point.y,
                        "resolved_point_x": resolvedPoint?.x ?? -1,
                        "resolved_point_y": resolvedPoint?.y ?? -1,
                        "suppress_path_hover": suppressCommandPathHover
                    ]
                )
            }
#endif
            return nil
        }

        // Refresh ghostty's cached mouse position so quicklook_word reads
        // up-to-date coordinates (mouseDown skips pos update on double-click).
        if let resolvedPoint {
            ghostty_surface_mouse_pos(
                surface,
                resolvedPoint.x,
                bounds.height - resolvedPoint.y,
                modsFromFlags(modifierFlags)
            )
        }

        guard let resolution = resolveWordUnderCursorPath(at: resolvedPoint) else {
#if DEBUG
            runtimeDebugLog(
                hypothesisID: "h2",
                name: "command_click_release",
                expected: "cmd-click should resolve the token under the pointer",
                actual: "no_resolution",
                data: [
                    "flags": debugModifierString(modifierFlags),
                    "ghostty_consumed": ghosttyConsumed,
                    "point_x": point.x,
                    "point_y": point.y,
                    "resolved_point_x": resolvedPoint?.x ?? -1,
                    "resolved_point_y": resolvedPoint?.y ?? -1
                ]
            )
#endif
            return nil
        }
        guard !ghosttyConsumed || resolution.source == .snapshot else {
#if DEBUG
            var payload: [String: Any] = [
                "flags": debugModifierString(modifierFlags),
                "ghostty_consumed": ghosttyConsumed,
                "point_x": point.x,
                "point_y": point.y,
                "resolved_point_x": resolvedPoint?.x ?? -1,
                "resolved_point_y": resolvedPoint?.y ?? -1,
                "suppress_path_hover": suppressCommandPathHover
            ]
            for (key, value) in runtimeDebugResolutionPayload(resolution) {
                payload[key] = value
            }
            runtimeDebugLog(
                hypothesisID: "h3",
                name: "command_click_release",
                expected: "ghostty-consumed clicks should only skip fallback for real ghostty targets",
                actual: "consumed_quicklook_resolution_skipped",
                data: payload
            )
#endif
            return nil
        }

        #if DEBUG
        cmuxDebugLog(
            "link.wordFallback resolved=\(resolution.path) source=\(resolution.source.rawValue) consumed=\(ghosttyConsumed ? 1 : 0)"
        )
        var payload: [String: Any] = [
            "flags": debugModifierString(modifierFlags),
            "ghostty_consumed": ghosttyConsumed,
            "point_x": point.x,
            "point_y": point.y,
            "resolved_point_x": resolvedPoint?.x ?? -1,
            "resolved_point_y": resolvedPoint?.y ?? -1,
            "suppress_path_hover": suppressCommandPathHover
        ]
        for (key, value) in runtimeDebugResolutionPayload(resolution) {
            payload[key] = value
        }
        runtimeDebugLog(
            hypothesisID: resolution.source == .snapshot ? "h3" : "h2",
            name: "command_click_release",
            expected: "cmd-click should open the resolved path",
            actual: "opening_resolved_path",
            data: payload
        )
        #endif

        // Remote-surface guard runs before shouldRoute so we never stat a local
        // path on the main thread for a remote workspace. When the cmux route
        // is applicable but split creation fails, fall back to the preferred
        // editor so the click never silently no-ops.
        if let termSurface = terminalSurface,
           let workspace = termSurface.owningWorkspace(),
           !workspace.isRemoteTerminalSurface(termSurface.id),
           CommandClickFileOpenRouter.openInCmux(
               workspace: workspace,
               sourcePanelId: termSurface.id,
               filePath: resolution.path
           ) {
            return resolution
        }

        PreferredEditorSettings.open(URL(fileURLWithPath: resolution.path))
        return resolution
    }

    private func clampedDebugPoint(_ point: NSPoint) -> NSPoint {
        NSPoint(
            x: min(max(point.x, 1), max(bounds.width - 1, 1)),
            y: min(max(point.y, 1), max(bounds.height - 1, 1))
        )
    }

#if DEBUG
    func debugSimulateSelection(from startPoint: NSPoint, to endPoint: NSPoint) -> Bool {
        guard let surface else { return false }
        let start = clampedDebugPoint(startPoint)
        let end = clampedDebugPoint(endPoint)
        let mods = GHOSTTY_MODS_NONE

        window?.makeFirstResponder(self)
        ghostty_surface_mouse_pos(surface, start.x, bounds.height - start.y, mods)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)

        let steps = max(4, Int(max(abs(end.x - start.x), abs(end.y - start.y)) / max(cellSize.width, 1)))
        for step in 1...steps {
            let progress = CGFloat(step) / CGFloat(steps)
            let intermediatePoint = NSPoint(
                x: start.x + ((end.x - start.x) * progress),
                y: start.y + ((end.y - start.y) * progress)
            )
            let clampedIntermediatePoint = clampedDebugPoint(intermediatePoint)
            ghostty_surface_mouse_pos(
                surface,
                clampedIntermediatePoint.x,
                bounds.height - clampedIntermediatePoint.y,
                mods
            )
        }

        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
        return ghostty_surface_has_selection(surface)
    }

    func debugSimulateCommandHover(at point: NSPoint) -> Bool {
        guard let surface else { return false }
        let clampedPoint = clampedDebugPoint(point)
        let flags: NSEvent.ModifierFlags = [.command]
        let suppressCommandPathHover = shouldSuppressCommandPathHover(for: flags)

        ghostty_surface_mouse_pos(
            surface,
            clampedPoint.x,
            bounds.height - clampedPoint.y,
            hoverModsFromFlags(
                flags,
                suppressCommandPathHover: suppressCommandPathHover
            )
        )
        updateWordPathHover(
            at: clampedPoint,
            cmdHeld: true,
            suppressPathHover: suppressCommandPathHover
        )
        return suppressCommandPathHover
    }

    func debugSimulateCommandHoverDetails(at point: NSPoint) -> [String: Any] {
        guard let surface else {
            return ["error": "Missing surface"]
        }

        let clampedPoint = clampedDebugPoint(point)
        let flags: NSEvent.ModifierFlags = [.command]
        let suppressCommandPathHover = shouldSuppressCommandPathHover(for: flags)

        ghostty_surface_mouse_pos(
            surface,
            clampedPoint.x,
            bounds.height - clampedPoint.y,
            hoverModsFromFlags(
                flags,
                suppressCommandPathHover: suppressCommandPathHover
            )
        )

        let resolution = suppressCommandPathHover ? nil : resolveWordUnderCursorPath(at: clampedPoint)
        updateWordPathHover(
            at: clampedPoint,
            cmdHeld: true,
            suppressPathHover: suppressCommandPathHover
        )

        var payload: [String: Any] = [
            "hoverActive": wordPathHoverActive ? "1" : "0",
            "suppressed": suppressCommandPathHover ? "1" : "0"
        ]
        if let resolution {
            payload["resolvedPath"] = resolution.path
            payload["resolutionSource"] = resolution.source.rawValue
            payload["rawToken"] = resolution.rawToken
        }
        return payload
    }

    func debugSimulateCommandClick(at point: NSPoint) -> [String: Any] {
        guard let surface else {
            return ["error": "Missing surface"]
        }

        let clampedPoint = clampedDebugPoint(point)
        let flags: NSEvent.ModifierFlags = [.command]
        let mods = modsFromFlags(flags)

        window?.makeFirstResponder(self)
        ghostty_surface_mouse_pos(surface, clampedPoint.x, bounds.height - clampedPoint.y, mods)
        let pressHandled = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)
        let releaseConsumed = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
        let resolution = handleCommandClickRelease(
            at: clampedPoint,
            modifierFlags: flags,
            ghosttyConsumed: releaseConsumed
        )

        var payload: [String: Any] = [
            "pressHandled": pressHandled ? "1" : "0",
            "releaseConsumed": releaseConsumed ? "1" : "0",
        ]
        if let resolution {
            payload["openedPath"] = resolution.path
            payload["resolutionSource"] = resolution.source.rawValue
            payload["rawToken"] = resolution.rawToken
        }
        return payload
    }
#endif

    override func rightMouseDown(with event: NSEvent) {
        guard let surface = surface else { return }
        if !ghostty_surface_mouse_captured(surface) {
            requestPointerFocusRecovery()
            super.rightMouseDown(with: event)
            return
        }

        requestPointerFocusRecovery()
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, modsFromEvent(event))
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface = surface else { return }
        if !ghostty_surface_mouse_captured(surface) {
            super.rightMouseUp(with: event)
            return
        }

        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, modsFromEvent(event))
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        requestPointerFocusRecovery()
        window?.makeFirstResponder(self)
        guard let surface = surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE, modsFromEvent(event))
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseUp(with: event)
            return
        }
        guard let surface = surface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE, modsFromEvent(event))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let surface = surface else { return nil }
        if ghostty_surface_mouse_captured(surface) {
            return nil
        }

        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, modsFromEvent(event))

        let menu = NSMenu()
        if onTriggerFlash != nil {
            let flashItem = menu.addItem(
                withTitle: String(localized: "terminalContextMenu.triggerFlash", defaultValue: "Trigger Flash"),
                action: #selector(triggerFlash(_:)),
                keyEquivalent: ""
            )
            flashItem.target = self
            menu.addItem(.separator())
        }
        if ghostty_surface_has_selection(surface) {
            let item = menu.addItem(
                withTitle: String(localized: "terminalContextMenu.copy", defaultValue: "Copy"),
                action: #selector(copy(_:)),
                keyEquivalent: ""
            )
            item.target = self
        }
        let pasteItem = menu.addItem(
            withTitle: String(localized: "terminalContextMenu.paste", defaultValue: "Paste"),
            action: #selector(paste(_:)),
            keyEquivalent: ""
        )
        pasteItem.target = self
        menu.addItem(.separator())
        let splitHorizontallyItem = menu.addItem(
            withTitle: String(localized: "terminalContextMenu.splitHorizontally", defaultValue: "Split Horizontally"),
            action: #selector(splitHorizontally(_:)),
            keyEquivalent: ""
        )
        splitHorizontallyItem.target = self
        applyConfiguredMenuShortcut(KeyboardShortcutSettings.menuShortcut(for: .splitDown), to: splitHorizontallyItem)
        splitHorizontallyItem.image = NSImage(
            systemSymbolName: "rectangle.bottomhalf.inset.filled",
            accessibilityDescription: nil
        )

        let splitVerticallyItem = menu.addItem(
            withTitle: String(localized: "terminalContextMenu.splitVertically", defaultValue: "Split Vertically"),
            action: #selector(splitVertically(_:)),
            keyEquivalent: ""
        )
        splitVerticallyItem.target = self
        applyConfiguredMenuShortcut(KeyboardShortcutSettings.menuShortcut(for: .splitRight), to: splitVerticallyItem)
        splitVerticallyItem.image = NSImage(
            systemSymbolName: "rectangle.righthalf.inset.filled",
            accessibilityDescription: nil
        )
        appendMoveCurrentSurfaceMoveMenuItems(to: menu); menu.addItem(.separator())
        let resetTerminalItem = menu.addItem(
            withTitle: String(localized: "terminalContextMenu.resetTerminal", defaultValue: "Reset Terminal"),
            action: #selector(resetTerminal(_:)),
            keyEquivalent: ""
        )
        resetTerminalItem.target = self
        resetTerminalItem.image = NSImage(
            systemSymbolName: "arrow.trianglehead.2.clockwise",
            accessibilityDescription: nil
        )
        if terminalSurface != nil {
            menu.addItem(.separator())
            let identifiersItem = menu.addItem(
                withTitle: String(localized: "terminalContextMenu.copyIdentifiers", defaultValue: "Copy IDs"),
                action: #selector(copyWorkspaceAndSurfaceIdentifiers(_:)),
                keyEquivalent: ""
            )
            identifiersItem.target = self
            let linkItem = menu.addItem(
                withTitle: String(localized: "command.copySurfaceLink.title", defaultValue: "Copy Surface Link"),
                action: #selector(copyCurrentSurfaceLink(_:)),
                keyEquivalent: ""
            )
            linkItem.target = self
        }
        return menu
    }

    private func canSplitCurrentSurface() -> Bool {
        guard let tabId,
              let surfaceId = terminalSurface?.id,
              let app = AppDelegate.shared,
              let manager = app.tabManagerFor(tabId: tabId) ?? app.tabManager,
              let workspace = manager.tabs.first(where: { $0.id == tabId }) else {
            return false
        }
        return workspace.panels[surfaceId] != nil
    }

    @objc private func splitHorizontally(_ sender: Any?) {
        _ = splitCurrentSurface(direction: .down)
    }

    @objc private func splitVertically(_ sender: Any?) {
        _ = splitCurrentSurface(direction: .right)
    }

    @discardableResult
    private func splitCurrentSurface(direction: SplitDirection) -> Bool {
        guard let tabId,
              let surfaceId = terminalSurface?.id,
              let app = AppDelegate.shared,
              let manager = app.tabManagerFor(tabId: tabId) ?? app.tabManager else {
            return false
        }
        return manager.createSplit(tabId: tabId, surfaceId: surfaceId, direction: direction) != nil
    }

    @objc private func triggerFlash(_ sender: Any?) {
        onTriggerFlash?()
    }

    @objc private func resetTerminal(_ sender: Any?) {
        _ = performBindingAction("reset")
    }

    override func mouseMoved(with event: NSEvent) {
        maybeRequestFirstResponderForMouseFocus()
        guard let surface = surface else { return }
        let suppressCommandPathHover = shouldSuppressCommandPathHover(for: event.modifierFlags)
        let eventPoint = convert(event.locationInWindow, from: nil)
        trackMousePointIfUsable(eventPoint)
        ghostty_surface_mouse_pos(
            surface,
            eventPoint.x,
            bounds.height - eventPoint.y,
            hoverModsFromFlags(
                event.modifierFlags,
                suppressCommandPathHover: suppressCommandPathHover
            )
        )
        updateWordPathHover(
            at: eventPoint,
            cmdHeld: event.modifierFlags.contains(.command),
            suppressPathHover: suppressCommandPathHover
        )
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        maybeRequestFirstResponderForMouseFocus()
        guard let surface = surface else { return }
        let suppressCommandPathHover = shouldSuppressCommandPathHover(for: event.modifierFlags)
        let eventPoint = convert(event.locationInWindow, from: nil)
        trackMousePointIfUsable(eventPoint)
        ghostty_surface_mouse_pos(
            surface,
            eventPoint.x,
            bounds.height - eventPoint.y,
            hoverModsFromFlags(
                event.modifierFlags,
                suppressCommandPathHover: suppressCommandPathHover
            )
        )
        updateWordPathHover(
            at: eventPoint,
            cmdHeld: event.modifierFlags.contains(.command),
            suppressPathHover: suppressCommandPathHover
        )
    }

    private func maybeRequestFirstResponderForMouseFocus() {
        guard let window else { return }
        let alreadyFirstResponder = window.firstResponder === self
        let shouldRequest = Self.shouldRequestFirstResponderForMouseFocus(
            focusFollowsMouseEnabled: GhosttyApp.shared.focusFollowsMouseEnabled(),
            pressedMouseButtons: NSEvent.pressedMouseButtons,
            appIsActive: NSApp.isActive,
            windowIsKey: window.isKeyWindow,
            alreadyFirstResponder: alreadyFirstResponder,
            visibleInUI: isVisibleInUI,
            hasUsableGeometry: hasUsableFocusGeometry,
            hiddenInHierarchy: isHiddenOrHasHiddenAncestor
        )
        guard shouldRequest else { return }
        window.makeFirstResponder(self)
    }

    override func mouseExited(with event: NSEvent) {
        if wordPathHoverActive {
            wordPathHoverActive = false
            NSCursor.pop()
        }
        guard let surface = surface else { return }
        if NSEvent.pressedMouseButtons != 0 {
            return
        }
        ghostty_surface_mouse_pos(surface, -1, -1, modsFromEvent(event))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let surface = surface else { return }
        let eventPoint = convert(event.locationInWindow, from: nil)
        trackMousePointIfUsable(eventPoint)
        // Forward the raw drag coordinates, including out-of-bounds positions.
        // Selection auto-scroll depends on libghostty observing the pointer leave
        // the viewport rather than a cached in-bounds hover point.
        ghostty_surface_mouse_pos(surface, eventPoint.x, bounds.height - eventPoint.y, modsFromEvent(event))
    }

#if DEBUG
    func debugHasPendingLeftMouseReleaseForTesting() -> Bool {
        hasPendingLeftMouseRelease
    }
#endif

    override func scrollWheel(with event: NSEvent) {
        NotificationCenter.default.post(name: .ghosttyDidReceiveWheelScroll, object: self)
        guard let surface = surface else { return }
        lastScrollEventTime = CACurrentMediaTime()
        Self.focusLog("scrollWheel: surface=\(terminalSurface?.id.uuidString ?? "nil") firstResponder=\(String(describing: window?.firstResponder))")
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precision = event.hasPreciseScrollingDeltas
        if precision {
            x *= 2
            y *= 2
        }

        var mods: Int32 = 0
        if precision {
            mods |= 0b0000_0001
        }

        let momentum: Int32
        switch event.momentumPhase {
        case .began:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_BEGAN.rawValue)
        case .stationary:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_STATIONARY.rawValue)
        case .changed:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_CHANGED.rawValue)
        case .ended:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_ENDED.rawValue)
        case .cancelled:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_CANCELLED.rawValue)
        case .mayBegin:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN.rawValue)
        default:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_NONE.rawValue)
        }
        mods |= momentum << 1

        // Track scroll state for lag detection
        let hasMomentum = event.momentumPhase != [] && event.momentumPhase != .mayBegin
        let momentumEnded = event.momentumPhase == .ended || event.momentumPhase == .cancelled
        GhosttyApp.shared.markScrollActivity(hasMomentum: hasMomentum, momentumEnded: momentumEnded)

        ghostty_surface_mouse_scroll(
            surface,
            x,
            y,
            ghostty_input_scroll_mods_t(mods)
        )
    }

    deinit {
        // Surface lifecycle is managed by TerminalSurface, not the view
#if DEBUG
        cmuxDebugLog(
            "surface.view.deinit view=\(Unmanaged.passUnretained(self).toOpaque()) " +
            "surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
            "inWindow=\(window != nil ? 1 : 0) hasSuperview=\(superview != nil ? 1 : 0)"
        )
#endif
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        if let windowObserver {
            NotificationCenter.default.removeObserver(windowObserver)
        }
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        terminalSurface = nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [
                .mouseEnteredAndExited,
                .mouseMoved,
                .inVisibleRect,
                .activeAlways,
            ],
            owner: self,
            userInfo: nil
        )

        if let trackingArea {
            addTrackingArea(trackingArea)
        }
    }

    private func windowDidChangeScreen(_ notification: Notification) {
        guard let window else { return }
        guard let object = notification.object as? NSWindow, window == object else { return }
        guard let screen = window.screen else { return }
        guard let surface = terminalSurface?.surface else { return }

        if let displayID = screen.displayID,
           displayID != 0 {
            ghostty_surface_set_display_id(surface, displayID)
        }

        DispatchQueue.main.async { [weak self] in
            self?.viewDidChangeBackingProperties()
        }
    }

    fileprivate static func escapeDropForShell(_ value: String) -> String {
        TerminalImageTransferPlanner.escapeForShell(value)
    }

    static func dropPlanForTesting(
        pasteboard: NSPasteboard,
        isRemoteTerminalSurface: Bool
    ) -> DropPlan {
        let target: TerminalImageTransferTarget = isRemoteTerminalSurface ? .remote(.workspaceRemote) : .local
        switch TerminalImageTransferPlanner.plan(
            pasteboard: pasteboard,
            mode: .drop,
            target: target
        ) {
        case .insertText(let text):
            return .insertText(text)
        case .insertTextSegments(let segments, _):
            return .insertText(segments.joined())
        case .uploadFiles(let fileURLs, _):
            return .uploadFiles(fileURLs)
        case .reject:
            return .reject
        }
    }

    static func performRemoteDropUploadForTesting(
        upload: (@escaping (Result<[String], Error>) -> Void) -> Void,
        sendText: @escaping (String) -> Void,
        onFailure: @escaping () -> Void
    ) {
        upload { result in
            switch result {
            case .success(let remotePaths):
                let content = remotePaths
                    .map { Self.escapeDropForShell($0) }
                    .joined(separator: " ")
                guard !content.isEmpty else {
                    onFailure()
                    return
                }
                sendText(content)
            case .failure:
                onFailure()
            }
        }
    }

    @discardableResult
    static func handleDropForTesting(
        pasteboard: NSPasteboard,
        isRemoteTerminalSurface: Bool,
        uploadRemote: ([URL], @escaping (Result<[String], Error>) -> Void) -> Void,
        sendText: @escaping (String) -> Void,
        onFailure: @escaping () -> Void
    ) -> Bool {
        let target: TerminalImageTransferTarget = isRemoteTerminalSurface ? .remote(.workspaceRemote) : .local
        let plan = TerminalImageTransferPlanner.plan(
            pasteboard: pasteboard,
            mode: .drop,
            target: target
        )
        guard plan != .reject else { return false }

        TerminalImageTransferPlanner.execute(
            plan: plan,
            uploadWorkspaceRemote: { urls, _, finish in
                uploadRemote(urls) { result in
                    finish(result)
                    GhosttyPasteboardHelper.cleanupTransferredTemporaryImageFiles(urls)
                }
            },
            uploadDetectedSSH: { _, _, _, finish in
                finish(.failure(NSError(domain: "cmux.remote.drop", code: 4)))
            },
            insertText: sendText,
            onFailure: { _ in onFailure() }
        )
        return true
    }

    private func executeImageTransferPlan(
        _ plan: TerminalImageTransferPlan,
        operation: TerminalImageTransferOperation? = nil,
        onCancel: @escaping () -> Void = {}
    ) -> Bool {
        guard plan != .reject else { return false }

        let operation = operation ?? {
            if case .uploadFiles = plan {
                return TerminalImageTransferOperation()
            }
            return nil
        }()

        if let operation {
            terminalSurface?.hostedView.beginImageTransferIndicator(
                for: operation,
                onCancel: onCancel
            )
        }

        TerminalImageTransferPlanner.execute(
            plan: plan,
            operation: operation,
            uploadWorkspaceRemote: { [weak self] fileURLs, operation, finish in
                guard let workspace = MainActor.assumeIsolated({
                    self?.terminalSurface?.owningWorkspace()
                }) else {
                    finish(.failure(NSError(domain: "cmux.remote.drop", code: 3)))
                    GhosttyPasteboardHelper.cleanupTransferredTemporaryImageFiles(fileURLs)
                    return
                }
                workspace.uploadDroppedFilesForRemoteTerminal(
                    fileURLs,
                    operation: operation,
                    completion: { result in
                        finish(result)
                        GhosttyPasteboardHelper.cleanupTransferredTemporaryImageFiles(fileURLs)
                    }
                )
            },
            uploadDetectedSSH: { session, fileURLs, operation, finish in
                session.uploadDroppedFiles(
                    fileURLs,
                    operation: operation,
                    completion: { result in
                        finish(result)
                        GhosttyPasteboardHelper.cleanupTransferredTemporaryImageFiles(fileURLs)
                    }
                )
            },
            insertText: { [weak self] text in
                let send = {
                    if let operation {
                        self?.terminalSurface?.hostedView.endImageTransferIndicator(for: operation)
                    }
                    // Use the text/paste path (ghostty_surface_text) instead of the key event
                    // path (ghostty_surface_key) so bracketed paste mode is triggered and the
                    // insertion is instant, matching upstream Ghostty behaviour.
                    self?.terminalSurface?.sendText(text)
                }
                if Thread.isMainThread {
                    send()
                } else {
                    DispatchQueue.main.async(execute: send)
                }
            },
            onFailure: { [weak self] _ in
                if let operation {
                    self?.terminalSurface?.hostedView.endImageTransferIndicator(for: operation)
                }
                DispatchQueue.main.async {
                    NSSound.beep()
#if DEBUG
                    cmuxDebugLog("terminal.remoteDropUpload.failed surface=\(self?.terminalSurface?.id.uuidString.prefix(5) ?? "nil")")
#endif
                }
            }
        )
        return true
    }

    private func resolvedImageTransferTarget() -> TerminalImageTransferTarget {
        MainActor.assumeIsolated {
            terminalSurface?.resolvedImageTransferTarget() ?? .local
        }
    }

    func handleDroppedFileURLs(_ urls: [URL]) -> Bool {
        executePreparedImageTransfer(
            .fileURLs(urls),
            onCancel: {}
        )
    }

    @discardableResult
    fileprivate func insertDroppedPasteboard(_ pasteboard: NSPasteboard) -> Bool {
        executePreparedImageTransfer(
            TerminalImageTransferPlanner.prepare(
                pasteboard: pasteboard,
                mode: .drop
            ),
            onCancel: {}
        )
    }

    @discardableResult
    private func executePreparedImageTransfer(
        _ preparedContent: TerminalImageTransferPreparedContent,
        onCancel: @escaping () -> Void
    ) -> Bool {
        switch preparedContent {
        case .reject:
            return false
        case .insertText(let text):
            terminalSurface?.sendText(text)
            return true
        case .fileURLs(let fileURLs):
            let plan = TerminalImageTransferPlanner.plan(
                fileURLs: fileURLs,
                target: resolvedImageTransferTarget(),
                mode: .drop
            )
            return executeImageTransferPlan(plan, onCancel: onCancel)
        }
    }

#if DEBUG
    fileprivate enum DebugDropPayloadKind {
        case fileURLs
        case imageData
    }

    @discardableResult
    func debugSimulateFileDrop(
        paths: [String],
        asImageData: Bool = false
    ) -> Bool {
        guard !paths.isEmpty else { return false }
        let pbName = NSPasteboard.Name("cmux.debug.drop.\(UUID().uuidString)")
        let pasteboard = NSPasteboard(name: pbName)
        pasteboard.clearContents()
        switch asImageData ? DebugDropPayloadKind.imageData : .fileURLs {
        case .fileURLs:
            let urls = paths.map { URL(fileURLWithPath: $0) as NSURL }
            pasteboard.writeObjects(urls)
        case .imageData:
            let items = paths.compactMap { path -> NSPasteboardItem? in
                let url = URL(fileURLWithPath: path)
                guard let data = try? Data(contentsOf: url),
                      let type = debugImagePasteboardType(for: url) else { return nil }
                let item = NSPasteboardItem()
                item.setData(data, forType: type)
                return item
            }
            guard items.count == paths.count else { return false }
            pasteboard.writeObjects(items)
        }
        return insertDroppedPasteboard(pasteboard)
    }

    private func debugImagePasteboardType(for url: URL) -> NSPasteboard.PasteboardType? {
        let pathExtension = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let utType = UTType(filenameExtension: pathExtension),
              utType.conforms(to: .image) else { return nil }
        return NSPasteboard.PasteboardType(utType.identifier)
    }

    func debugRegisteredDropTypes() -> [String] {
        (registeredDraggedTypes ?? []).map(\.rawValue)
    }
#endif

    // MARK: NSDraggingDestination

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        #if DEBUG
        let types = sender.draggingPasteboard.types ?? []
        cmuxDebugLog("terminal.draggingEntered surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil") types=\(types.map(\.rawValue))")
        #endif
        guard let types = sender.draggingPasteboard.types else { return [] }
        // Defer to bonsplit when a tab/session drag is in flight: bonsplit's pane
        // drop overlays should win over the terminal's text/file drop handling.
        if types.contains(Self.tabTransferPasteboardType) || types.contains(Self.sidebarTabReorderPasteboardType) {
            return []
        }
        if Set(types).isDisjoint(with: Self.dropTypes) {
            return []
        }
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        #if DEBUG
        let types = sender.draggingPasteboard.types ?? []
        cmuxDebugLog("terminal.draggingUpdated surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil") types=\(types.map(\.rawValue))")
        #endif
        guard let types = sender.draggingPasteboard.types else { return [] }
        if types.contains(Self.tabTransferPasteboardType) || types.contains(Self.sidebarTabReorderPasteboardType) {
            return []
        }
        if Set(types).isDisjoint(with: Self.dropTypes) {
            return []
        }
        return .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let types = sender.draggingPasteboard.types ?? []
        if types.contains(Self.tabTransferPasteboardType) || types.contains(Self.sidebarTabReorderPasteboardType) {
            return false
        }
        #if DEBUG
        cmuxDebugLog("terminal.fileDrop surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil")")
        #endif
        return insertDroppedPasteboard(sender.draggingPasteboard)
    }
}


// MARK: - NSTextInputClient

extension GhosttyNSView: NSTextInputClient {
    /// Deliver committed text using typed-input semantics so shells and editors
    /// keep their normal interactive behaviors (autosuggestions, Return
    /// execution, etc.). Programmatic callers can preserve literal ESC bytes so
    /// automation payloads remain byte-for-byte stable.
    fileprivate func sendTextToSurface(_ chars: String, preserveLiteralEscape: Bool) {
        guard let surface = surface else { return }
#if DEBUG
        let typingTimingStart = CmuxTypingTiming.start()
#endif
#if DEBUG
        cmuxWriteChildExitProbe(
            [
                "probeInsertTextCharsHex": cmuxScalarHex(chars),
                "probeInsertTextSurfaceId": terminalSurface?.id.uuidString ?? "",
            ],
            increments: ["probeInsertTextCount": 1]
        )
#endif

        var bufferedText = ""
        var previousWasCR = false

        func flushBufferedText() {
            guard !bufferedText.isEmpty else { return }
            var keyEvent = ghostty_input_key_s()
            keyEvent.action = GHOSTTY_ACTION_PRESS
            keyEvent.keycode = 0
            keyEvent.mods = GHOSTTY_MODS_NONE
            keyEvent.consumed_mods = GHOSTTY_MODS_NONE
            keyEvent.unshifted_codepoint = 0
            keyEvent.composing = false
            bufferedText.withCString { ptr in
                keyEvent.text = ptr
                _ = sendGhosttyKey(surface, keyEvent)
            }
            bufferedText.removeAll(keepingCapacity: true)
        }

        func sendControlKey(_ keycode: UInt32) {
            var keyEvent = ghostty_input_key_s()
            keyEvent.action = GHOSTTY_ACTION_PRESS
            keyEvent.keycode = keycode
            keyEvent.mods = GHOSTTY_MODS_NONE
            keyEvent.consumed_mods = GHOSTTY_MODS_NONE
            keyEvent.unshifted_codepoint = 0
            keyEvent.composing = false
            keyEvent.text = nil
            _ = sendGhosttyKey(surface, keyEvent)
        }

        for scalar in chars.unicodeScalars {
            switch scalar.value {
            case 0x0A:
                if !previousWasCR {
                    flushBufferedText()
                    sendControlKey(0x24) // kVK_Return
                }
                previousWasCR = false
            case 0x0D:
                flushBufferedText()
                sendControlKey(0x24) // kVK_Return
                previousWasCR = true
            case 0x09:
                flushBufferedText()
                sendControlKey(0x30) // kVK_Tab
                previousWasCR = false
            case 0x1B:
                if preserveLiteralEscape {
                    bufferedText.unicodeScalars.append(scalar)
                } else {
                    flushBufferedText()
                    sendControlKey(0x35) // kVK_Escape
                }
                previousWasCR = false
            default:
                bufferedText.unicodeScalars.append(scalar)
                previousWasCR = false
            }
        }
        flushBufferedText()
#if DEBUG
        CmuxTypingTiming.logDuration(
            path: "terminal.sendTextToSurface",
            startedAt: typingTimingStart,
            extra: "textBytes=\(chars.utf8.count)"
        )
#endif
    }

    /// External accessibility/dictation tools should commit plain text, but
    /// some inject a leading escape sequence first. Strip those bytes on the
    /// committed-text path so they can't leak into the PTY as literals.
    static func sanitizeExternalCommittedText(_ text: String) -> String {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { return text }

        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x1B {
                index = consumeLeadingEscapeSequence(in: bytes, from: index)
                continue
            }

            if byte == 0xC2 {
                let next = index + 1
                if next < bytes.count, bytes[next] == 0x9B {
                    // U+009B (C1 CSI) is encoded as the UTF-8 byte pair C2 9B.
                    index = consumeLeadingCSISequence(in: bytes, from: next + 1)
                    continue
                }
            }

            break
        }

        if index == 0 {
            return text
        }

        guard index < bytes.count else { return "" }
        return String(decoding: bytes[index...], as: UTF8.self)
    }

    private static func consumeLeadingEscapeSequence(
        in bytes: [UInt8],
        from start: Int
    ) -> Int {
        let next = start + 1
        guard next < bytes.count else { return bytes.count }

        switch bytes[next] {
        case 0x5B:
            // CSI: ESC [ ... final
            return consumeLeadingCSISequence(in: bytes, from: next + 1)
        case 0x4F:
            // SS3: ESC O final
            return min(bytes.count, next + 2)
        case 0x50, 0x5D, 0x5E, 0x5F:
            // DCS/OSC/PM/APC: consume until BEL/ST or EOF.
            return consumeLeadingEscapedStringSequence(in: bytes, from: next + 1)
        default:
            // Single-character escape.
            return min(bytes.count, next + 1)
        }
    }

    private static func consumeLeadingCSISequence(
        in bytes: [UInt8],
        from start: Int
    ) -> Int {
        var index = start
        while index < bytes.count {
            let byte = bytes[index]
            if (0x20...0x3F).contains(byte) {
                index += 1
                continue
            }

            if (0x40...0x7E).contains(byte) {
                return index + 1
            }

            break
        }

        return index
    }

    private static func consumeLeadingEscapedStringSequence(
        in bytes: [UInt8],
        from start: Int
    ) -> Int {
        var index = start
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x07 {
                return index + 1
            }

            if byte == 0x1B {
                let next = index + 1
                if next < bytes.count, bytes[next] == 0x5C {
                    return next + 1
                }
                return index
            }

            if byte < 0x20 || byte == 0x7F {
                return index + 1
            }

            index += 1
        }

        return bytes.count
    }

    func hasMarkedText() -> Bool {
        return markedText.length > 0
    }

    func markedRange() -> NSRange {
        guard markedText.length > 0 else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: 0, length: markedText.length)
    }

    func selectedRange() -> NSRange {
        if markedText.length > 0 {
#if DEBUG
            assert(markedSelectedRange.location != NSNotFound, "markedSelectedRange must be valid")
#endif
            return markedSelectedRange
        }
        return readSelectionSnapshot()?.range ?? NSRange(location: 0, length: 0)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
#if DEBUG
        let typingTimingStart = CmuxTypingTiming.start()
        defer {
            CmuxTypingTiming.logDuration(
                path: "terminal.setMarkedText",
                startedAt: typingTimingStart,
                extra: "markedLength=\(markedText.length)"
            )
        }
#endif
        switch string {
        case let v as NSAttributedString:
            markedText = NSMutableAttributedString(attributedString: v)
        case let v as String:
            markedText = NSMutableAttributedString(string: v)
        default:
            return
        }
        markedSelectedRange = normalizedMarkedSelectionRange(selectedRange, markedLength: markedText.length)

        // If we're not in a keyDown event, sync preedit immediately.
        // This can happen due to external events like changing keyboard layouts
        // while composing.
        if keyTextAccumulator == nil {
            syncPreedit()
            invalidateTextInputCoordinates(selectionChanged: true)
        }
    }

    func unmarkText() {
#if DEBUG
        let hadMarkedText = markedText.length > 0
        let typingTimingStart = CmuxTypingTiming.start()
        defer {
            CmuxTypingTiming.logDuration(
                path: "terminal.unmarkText",
                startedAt: typingTimingStart,
                extra: "hadMarkedText=\(hadMarkedText ? 1 : 0)"
            )
        }
#endif
        if markedText.length > 0 {
            markedText.mutableString.setString("")
            markedSelectedRange = NSRange(location: NSNotFound, length: 0)
            syncPreedit()
            invalidateTextInputCoordinates(selectionChanged: true)
        }
    }

    /// Sync the preedit state based on the markedText value to libghostty.
    /// This tells Ghostty about IME composition text so it can render the
    /// preedit overlay (e.g. for Korean, Japanese, Chinese input).
    private func syncPreedit(clearIfNeeded: Bool = true) {
#if DEBUG
        let typingTimingStart = CmuxTypingTiming.start()
        defer {
            CmuxTypingTiming.logDuration(
                path: "terminal.syncPreedit",
                startedAt: typingTimingStart,
                extra: "markedLength=\(markedText.length) clearIfNeeded=\(clearIfNeeded ? 1 : 0)"
            )
        }
#endif
        guard let surface = surface else { return }

        if markedText.length > 0 {
            let str = markedText.string
            let len = str.utf8CString.count
            if len > 0 {
                str.withCString { ptr in
                    // Subtract 1 for the null terminator
                    ghostty_surface_preedit(surface, ptr, UInt(len - 1))
                }
            }
        } else if clearIfNeeded {
            // If we had marked text before but don't now, we're no longer
            // in a preedit state so we can clear it.
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        return []
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        if markedText.length > 0 {
            guard let substringRange = clampedMarkedTextRange(range, markedLength: markedText.length) else { return nil }
            actualRange?.pointee = substringRange
            return markedText.attributedSubstring(from: substringRange)
        }

        guard range.length > 0,
              let snapshot = readSelectionSnapshot() else { return nil }
        actualRange?.pointee = snapshot.range
        return NSAttributedString(string: snapshot.string)
    }

    func characterIndex(for point: NSPoint) -> Int {
        return selectedRange().location
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window = self.window else {
            return NSRect(x: frame.origin.x, y: frame.origin.y, width: 0, height: 0)
        }

        // Use Ghostty's IME point API for accurate cursor position if available.
        var x: Double = 0
        var y: Double = 0
        var w: Double = cellSize.width
        var h: Double = cellSize.height
#if DEBUG
        if range.length > 0,
           range != selectedRange(),
           let snapshot = readSelectionSnapshot() {
            x = snapshot.topLeft.x - 2
            y = snapshot.topLeft.y + 2
        } else if let override = imePointOverrideForTesting {
            x = override.x
            y = override.y
            w = override.width
            h = override.height
        } else if let surface = surface {
            ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        }
#else
        if range.length > 0,
           range != selectedRange(),
           let snapshot = readSelectionSnapshot() {
            x = snapshot.topLeft.x - 2
            y = snapshot.topLeft.y + 2
        } else if let surface = surface {
            ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        }
#endif

        if range.length == 0, w > 0 {
            // Dictation expects a caret rect for insertion points rather than a box.
            w = 0
        }

        // Ghostty coordinates are top-left origin; AppKit expects bottom-left.
        let viewRect = NSRect(
            x: x,
            y: frame.size.height - y,
            width: w,
            height: max(h, cellSize.height)
        )
        let winRect = convert(viewRect, to: nil)
        return window.convertToScreen(winRect)
    }

    func attributedString() -> NSAttributedString {
        if markedText.length > 0 {
            return NSAttributedString(attributedString: markedText)
        }
        if let snapshot = readSelectionSnapshot(), !snapshot.string.isEmpty {
            return NSAttributedString(string: snapshot.string)
        }
        return NSAttributedString(string: "")
    }

    func windowLevel() -> Int {
        Int(window?.level.rawValue ?? NSWindow.Level.normal.rawValue)
    }

    @available(macOS 14.0, *)
    var unionRectInVisibleSelectedRange: NSRect {
        firstRect(forCharacterRange: selectedRange(), actualRange: nil)
    }

    @available(macOS 14.0, *)
    var documentVisibleRect: NSRect {
        visibleDocumentRectInScreenCoordinates()
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
#if DEBUG
        let typingTimingStart = CmuxTypingTiming.start()
        defer {
            CmuxTypingTiming.logDuration(
                path: "terminal.insertText",
                startedAt: typingTimingStart,
                event: NSApp.currentEvent,
                extra: "replacementLocation=\(replacementRange.location) replacementLength=\(replacementRange.length)"
            )
        }
#endif
        // Get the string value
        var chars = ""
        switch string {
        case let v as NSAttributedString:
            chars = v.string
        case let v as String:
            chars = v
        default:
            return
        }

        if keyTextAccumulator != nil,
           shouldBufferBopomofoInsertedPreedit(chars) {
            insertBopomofoPreeditText(chars, replacementRange: replacementRange)
            return
        }

        // Clear marked text since we're inserting
        unmarkText()

        // Some IME/input-method paths call insertText with an empty payload to
        // flush state. There is no terminal text to send in that case.
        guard !chars.isEmpty else { return }

        if shouldSuppressDeferredNumpadIMECommit(chars) {
            return
        }

#if DEBUG
        if NSApp.currentEvent == nil {
            cmuxDebugLog("ime.insertText.noEvent len=\(chars.count)")
        }
#endif

        // If we have an accumulator, we're in a keyDown event - accumulate the text
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(chars)
            return
        }

        let isExternalCommittedText = externalCommittedTextDepth > 0
        let sanitizedChars = if isExternalCommittedText {
            // Only sanitize explicit external committed-text paths used by
            // AX/dictation integrations. Programmatic NSTextInputClient callers
            // may intentionally start with ESC/CSI bytes.
            Self.sanitizeExternalCommittedText(chars)
        } else {
            chars
        }

#if DEBUG
        if sanitizedChars != chars {
            cmuxDebugLog(
                "ime.insertText.sanitized originalBytes=\(chars.utf8.count) " +
                "sanitizedBytes=\(sanitizedChars.utf8.count)"
            )
        }
#endif

        guard !sanitizedChars.isEmpty else { return }

        // Otherwise send directly to the terminal
        recordDirectAgentHibernationTerminalInput()
        sendTextToSurface(
            sanitizedChars,
            preserveLiteralEscape: !isExternalCommittedText
        )
    }

    private func insertBopomofoPreeditText(_ chars: String, replacementRange: NSRange) {
        let effectiveRange = effectiveBopomofoPreeditReplacementRange(replacementRange)
        if let range = Range(effectiveRange, in: markedText.string) {
            let insertionLocation = effectiveRange.location + (chars as NSString).length
            let next = markedText.string.replacingCharacters(in: range, with: chars)
            markedText = NSMutableAttributedString(string: next)
            markedSelectedRange = normalizedMarkedSelectionRange(
                NSRange(location: insertionLocation, length: 0),
                markedLength: markedText.length
            )
            return
        }

        markedText.append(NSAttributedString(string: chars))
        markedSelectedRange = normalizedMarkedSelectionRange(
            NSRange(location: markedText.length, length: 0),
            markedLength: markedText.length
        )
    }

    private func effectiveBopomofoPreeditReplacementRange(_ replacementRange: NSRange) -> NSRange {
        guard replacementRange.location == NSNotFound else { return replacementRange }
        guard markedText.length > 0 else { return NSRange(location: 0, length: 0) }
        return normalizedMarkedSelectionRange(markedSelectedRange, markedLength: markedText.length)
    }
}

// MARK: - SwiftUI Wrapper

struct GhosttyTerminalView: NSViewRepresentable {
    @Environment(\.paneDropZone) var paneDropZone

    let terminalSurface: TerminalSurface
    let paneId: PaneID
    var isActive: Bool = true
    var isVisibleInUI: Bool = true
    var portalZPriority: Int = 0
    var showsInactiveOverlay: Bool = false
    var showsUnreadNotificationRing: Bool = false
    var inactiveOverlayColor: NSColor = .clear
    var inactiveOverlayOpacity: Double = 0
    var searchState: TerminalSurface.SearchState? = nil
    var reattachToken: UInt64 = 0
    var onFocus: ((UUID) -> Void)? = nil
    var onTriggerFlash: (() -> Void)? = nil

    private final class HostContainerView: NSView {
        private static var nextInstanceSerial: UInt64 = 0

        var onDidMoveToWindow: (() -> Void)?
        var onGeometryChanged: (() -> Void)?
        let instanceSerial: UInt64
        private(set) var geometryRevision: UInt64 = 0
        private var lastReportedGeometryState: GeometryState?

        override init(frame frameRect: NSRect) {
            Self.nextInstanceSerial &+= 1
            instanceSerial = Self.nextInstanceSerial
            super.init(frame: frameRect)
            setContentHuggingPriority(.defaultLow, for: .horizontal)
            setContentHuggingPriority(.defaultLow, for: .vertical)
            setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) not implemented")
        }

        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }

        private struct GeometryState: Equatable {
            let frame: CGRect
            let bounds: CGRect
            let windowNumber: Int?
            let superviewID: ObjectIdentifier?
        }

        private func currentGeometryState() -> GeometryState {
            GeometryState(
                frame: frame,
                bounds: bounds,
                windowNumber: window?.windowNumber,
                superviewID: superview.map(ObjectIdentifier.init)
            )
        }

        private func notifyGeometryChangedIfNeeded() {
            let state = currentGeometryState()
            guard state != lastReportedGeometryState else { return }
            lastReportedGeometryState = state
            geometryRevision &+= 1
            onGeometryChanged?()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onDidMoveToWindow?()
            notifyGeometryChangedIfNeeded()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            notifyGeometryChangedIfNeeded()
        }

        override func layout() {
            super.layout()
            notifyGeometryChangedIfNeeded()
        }

        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(newOrigin)
            notifyGeometryChangedIfNeeded()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            notifyGeometryChangedIfNeeded()
        }
    }

    final class Coordinator {
        var attachGeneration: Int = 0
        // Track the latest desired state so attach retries can re-apply focus after re-parenting.
        var desiredIsActive: Bool = true
        var desiredIsVisibleInUI: Bool = true
        var desiredShowsUnreadNotificationRing: Bool = false
        var desiredPortalZPriority: Int = 0
        var lastBoundHostId: ObjectIdentifier?
        var lastPaneDropZone: DropZone?
        var lastSynchronizedHostGeometryRevision: UInt64 = 0
        weak var hostedView: GhosttySurfaceScrollView?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func shouldApplyImmediateHostedStateUpdate(
        desiredVisibleInUI: Bool, hostedViewHasSuperview: Bool, isBoundToCurrentHost: Bool
    ) -> Bool {
        if !desiredVisibleInUI { return true }
        // If this update originates from a stale/replaced host while the hosted view is
        // already attached elsewhere, do not mutate visibility/active state here.
        if isBoundToCurrentHost { return true }
        return !hostedViewHasSuperview
    }

    enum HostCallbackPortalGeometrySynchronizationAction<Window> {
        case skip
        case synchronizeWithoutLayoutFlush(Window)
    }

    static func hostCallbackPortalGeometrySynchronizationAction<Window>(
        window: Window?
    ) -> HostCallbackPortalGeometrySynchronizationAction<Window> {
        // HostContainerView callbacks can fire while SwiftUI/AppKit is already
        // rendering or laying out the representable. Keep the immediate path,
        // but forbid ancestor layout flushes from this callback.
        guard let window else { return .skip }
        return .synchronizeWithoutLayoutFlush(window)
    }

    private static func synchronizePortalGeometry(
        for host: HostContainerView,
        coordinator: Coordinator
    ) {
        let geometryRevision = host.geometryRevision
        guard coordinator.lastSynchronizedHostGeometryRevision != geometryRevision else { return }
        coordinator.lastSynchronizedHostGeometryRevision = geometryRevision
        // Avoid forcing ancestor AppKit layout while SwiftUI is still inside
        // the current update/layout turn. Reconcile the portal against the
        // already-current host geometry so terminal content tracks resize
        // without reopening the CATransaction display-link reentry path.
        guard case .synchronizeWithoutLayoutFlush = hostCallbackPortalGeometrySynchronizationAction(
            window: host.window
        ) else { return }
        TerminalWindowPortalRegistry.synchronizeForAnchor(host, syncLayout: false)
    }

    func makeNSView(context: Context) -> NSView {
        let container = HostContainerView(frame: .zero)
        container.wantsLayer = false
        // The actual terminal surface lives in the AppKit portal layer above SwiftUI.
        // This empty placeholder should not be walked by the accessibility subsystem.
        container.setAccessibilityRole(.none)
        container.setAccessibilityElement(false)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let hostedView = terminalSurface.hostedView
        let coordinator = context.coordinator
        let previousDesiredIsActive = coordinator.desiredIsActive
        let previousDesiredIsVisibleInUI = coordinator.desiredIsVisibleInUI
        let previousDesiredPortalZPriority = coordinator.desiredPortalZPriority
        let desiredStateChanged =
            previousDesiredIsActive != isActive ||
            previousDesiredIsVisibleInUI != isVisibleInUI ||
            previousDesiredPortalZPriority != portalZPriority
        coordinator.desiredIsActive = isActive
        coordinator.desiredIsVisibleInUI = isVisibleInUI
        coordinator.desiredShowsUnreadNotificationRing = showsUnreadNotificationRing
        coordinator.desiredPortalZPriority = portalZPriority
        coordinator.hostedView = hostedView
#if DEBUG
        if desiredStateChanged {
            if let snapshot = AppDelegate.shared?.tabManager?.debugCurrentWorkspaceSwitchSnapshot() {
                let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
                cmuxDebugLog(
                    "ws.swiftui.update id=\(snapshot.id) dt=\(String(format: "%.2fms", dtMs)) " +
                    "surface=\(terminalSurface.id.uuidString.prefix(5)) visible=\(isVisibleInUI ? 1 : 0) " +
                    "active=\(isActive ? 1 : 0) z=\(portalZPriority) " +
                    "hostWindow=\(nsView.window != nil ? 1 : 0) hostedWindow=\(hostedView.window != nil ? 1 : 0) " +
                    "hostedSuperview=\(hostedView.superview != nil ? 1 : 0)"
                )
            } else {
                cmuxDebugLog(
                    "ws.swiftui.update id=none surface=\(terminalSurface.id.uuidString.prefix(5)) " +
                    "visible=\(isVisibleInUI ? 1 : 0) active=\(isActive ? 1 : 0) z=\(portalZPriority) " +
                    "hostWindow=\(nsView.window != nil ? 1 : 0) hostedWindow=\(hostedView.window != nil ? 1 : 0) " +
                    "hostedSuperview=\(hostedView.superview != nil ? 1 : 0)"
                )
            }
        }
#endif

        let hostContainer = nsView as? HostContainerView
        let hostOwnsPortalNow = hostContainer.map { host in
            terminalSurface.claimPortalHost(
                hostId: ObjectIdentifier(host),
                paneId: paneId,
                instanceSerial: host.instanceSerial,
                inWindow: host.window != nil,
                bounds: host.bounds,
                reason: "update"
            )
        } ?? true

        // Keep the surface lifecycle and handlers updated even if we defer re-parenting.
        hostedView.attachSurface(terminalSurface)
        hostedView.setFocusHandler { onFocus?(terminalSurface.id) }
        hostedView.setTriggerFlashHandler(onTriggerFlash)
        if hostOwnsPortalNow {
            hostedView.setPaneDropContext(TerminalPaneDropContext(
                workspaceId: terminalSurface.tabId,
                panelId: terminalSurface.id,
                paneId: paneId
            ))
            hostedView.setInactiveOverlay(
                color: inactiveOverlayColor,
                opacity: CGFloat(inactiveOverlayOpacity),
                visible: showsInactiveOverlay
            )
            hostedView.setNotificationRing(visible: showsUnreadNotificationRing)
            hostedView.setSearchOverlay(searchState: searchState)
            hostedView.syncKeyStateIndicator(text: terminalSurface.currentKeyStateIndicatorText)
        }
        let portalExpectedSurfaceId = terminalSurface.id
        let portalExpectedGeneration = terminalSurface.portalBindingGeneration()
        func portalBindingStillLive() -> Bool {
            terminalSurface.canAcceptPortalBinding(
                expectedSurfaceId: portalExpectedSurfaceId,
                expectedGeneration: portalExpectedGeneration
            )
        }
        let forwardedDropZone = isVisibleInUI ? paneDropZone : nil
#if DEBUG
        if coordinator.lastPaneDropZone != paneDropZone {
            let oldZone = coordinator.lastPaneDropZone.map { String(describing: $0) } ?? "none"
            let newZone = paneDropZone.map { String(describing: $0) } ?? "none"
            cmuxDebugLog(
                "terminal.paneDropZone surface=\(terminalSurface.id.uuidString.prefix(5)) " +
                "old=\(oldZone) new=\(newZone) " +
                "active=\(isActive ? 1 : 0) visible=\(isVisibleInUI ? 1 : 0) " +
                "inWindow=\(hostedView.window != nil ? 1 : 0)"
            )
            coordinator.lastPaneDropZone = paneDropZone
        }
        if paneDropZone != nil, !isVisibleInUI {
            cmuxDebugLog(
                "terminal.paneDropZone.suppress surface=\(terminalSurface.id.uuidString.prefix(5)) " +
                "requested=\(String(describing: paneDropZone!)) visible=0 active=\(isActive ? 1 : 0)"
            )
        }
#endif
        if hostOwnsPortalNow {
            hostedView.setDropZoneOverlay(zone: forwardedDropZone)
        }

        coordinator.attachGeneration += 1
        let generation = coordinator.attachGeneration

        if let host = hostContainer {
            host.onDidMoveToWindow = { [weak host, weak hostedView, weak coordinator] in
                guard let host, let hostedView, let coordinator else { return }
                guard coordinator.attachGeneration == generation else { return }
                guard terminalSurface.claimPortalHost(
                    hostId: ObjectIdentifier(host),
                    paneId: paneId,
                    instanceSerial: host.instanceSerial,
                    inWindow: host.window != nil,
                    bounds: host.bounds,
                    reason: "didMoveToWindow"
                ) else { return }
                guard host.window != nil else { return }
                guard portalBindingStillLive() else { return }
                TerminalWindowPortalRegistry.bind(
                    hostedView: hostedView,
                    to: host,
                    visibleInUI: coordinator.desiredIsVisibleInUI,
                    zPriority: coordinator.desiredPortalZPriority,
                    expectedSurfaceId: portalExpectedSurfaceId,
                    expectedGeneration: portalExpectedGeneration,
                    deferLayoutSynchronization: true
                )
                coordinator.lastBoundHostId = ObjectIdentifier(host)
                coordinator.lastSynchronizedHostGeometryRevision = host.geometryRevision
                hostedView.setVisibleInUI(coordinator.desiredIsVisibleInUI)
                hostedView.setActive(coordinator.desiredIsActive)
                hostedView.setNotificationRing(visible: coordinator.desiredShowsUnreadNotificationRing)
            }
            host.onGeometryChanged = { [weak host, weak hostedView, weak coordinator] in
                guard let host, let hostedView, let coordinator else { return }
                guard coordinator.attachGeneration == generation else { return }
                guard terminalSurface.claimPortalHost(
                    hostId: ObjectIdentifier(host),
                    paneId: paneId,
                    instanceSerial: host.instanceSerial,
                    inWindow: host.window != nil,
                    bounds: host.bounds,
                    reason: "geometryChanged"
                ) else { return }
                guard portalBindingStillLive() else { return }
                let hostId = ObjectIdentifier(host)
                if host.window != nil,
                   (coordinator.lastBoundHostId != hostId ||
                    !TerminalWindowPortalRegistry.isHostedView(hostedView, boundTo: host)) {
#if DEBUG
                    cmuxDebugLog(
                        "ws.hostState.rebindOnGeometry surface=\(terminalSurface.id.uuidString.prefix(5)) " +
                        "reason=portalEntryMissing visible=\(coordinator.desiredIsVisibleInUI ? 1 : 0) " +
                        "active=\(coordinator.desiredIsActive ? 1 : 0) z=\(coordinator.desiredPortalZPriority)"
                    )
#endif
                    TerminalWindowPortalRegistry.bind(
                        hostedView: hostedView,
                        to: host,
                        visibleInUI: coordinator.desiredIsVisibleInUI,
                        zPriority: coordinator.desiredPortalZPriority,
                        expectedSurfaceId: portalExpectedSurfaceId,
                        expectedGeneration: portalExpectedGeneration,
                        deferLayoutSynchronization: true
                    )
                    coordinator.lastBoundHostId = hostId
                    hostedView.setVisibleInUI(coordinator.desiredIsVisibleInUI)
                    hostedView.setActive(coordinator.desiredIsActive)
                    hostedView.setNotificationRing(visible: coordinator.desiredShowsUnreadNotificationRing)
                }
                Self.synchronizePortalGeometry(
                    for: host,
                    coordinator: coordinator
                )
            }

            if host.window != nil, hostOwnsPortalNow {
                let portalBindingLive = portalBindingStillLive()
                let hostId = ObjectIdentifier(host)
                let geometryRevision = host.geometryRevision
                let portalEntryMissing = !TerminalWindowPortalRegistry.isHostedView(hostedView, boundTo: host)
                // Notification rings are hosted inside GhosttySurfaceScrollView and update in place.
                // A ring-only state change must not resynchronize the window portal while SwiftUI is
                // invalidating notification UI, or the terminal can be hidden until the next tab switch.
                let shouldBindNow =
                    coordinator.lastBoundHostId != hostId ||
                    hostedView.superview == nil ||
                    portalEntryMissing ||
                    previousDesiredIsVisibleInUI != isVisibleInUI ||
                    previousDesiredPortalZPriority != portalZPriority
                if portalBindingLive && shouldBindNow {
#if DEBUG
                    if portalEntryMissing {
                        cmuxDebugLog(
                            "ws.hostState.rebindOnUpdate surface=\(terminalSurface.id.uuidString.prefix(5)) " +
                            "reason=portalEntryMissing visible=\(coordinator.desiredIsVisibleInUI ? 1 : 0) " +
                            "active=\(coordinator.desiredIsActive ? 1 : 0) z=\(coordinator.desiredPortalZPriority)"
                        )
                    }
#endif
                    TerminalWindowPortalRegistry.bind(
                        hostedView: hostedView,
                        to: host,
                        visibleInUI: coordinator.desiredIsVisibleInUI,
                        zPriority: coordinator.desiredPortalZPriority,
                        expectedSurfaceId: portalExpectedSurfaceId,
                        expectedGeneration: portalExpectedGeneration,
                        deferLayoutSynchronization: true
                    )
                    coordinator.lastBoundHostId = hostId
                    coordinator.lastSynchronizedHostGeometryRevision = geometryRevision
                } else if portalBindingLive && coordinator.lastSynchronizedHostGeometryRevision != geometryRevision {
                    Self.synchronizePortalGeometry(
                        for: host,
                        coordinator: coordinator
                    )
                }
            } else if hostOwnsPortalNow, portalBindingStillLive() {
                // Bind is deferred until host moves into a window. Update the
                // existing portal entry's visibleInUI now so that any portal sync
                // that runs before the deferred bind completes won't hide the view.
#if DEBUG
                if desiredStateChanged {
                    cmuxDebugLog(
                        "ws.hostState.deferBind surface=\(terminalSurface.id.uuidString.prefix(5)) " +
                        "reason=hostNoWindow visible=\(coordinator.desiredIsVisibleInUI ? 1 : 0) " +
                        "active=\(coordinator.desiredIsActive ? 1 : 0) z=\(coordinator.desiredPortalZPriority) " +
                        "hostedWindow=\(hostedView.window != nil ? 1 : 0) hostedSuperview=\(hostedView.superview != nil ? 1 : 0)"
                    )
                }
#endif
                TerminalWindowPortalRegistry.updateEntryVisibility(
                    for: hostedView,
                    visibleInUI: coordinator.desiredIsVisibleInUI
                )
            }
        }

        let hostWindowAttached = hostContainer?.window != nil
        let isBoundToCurrentHost = hostContainer.map { host in
            TerminalWindowPortalRegistry.isHostedView(hostedView, boundTo: host)
        } ?? true
        let shouldApplyImmediateHostedState = hostOwnsPortalNow && Self.shouldApplyImmediateHostedStateUpdate(
            desiredVisibleInUI: isVisibleInUI,
            hostedViewHasSuperview: hostedView.superview != nil,
            isBoundToCurrentHost: isBoundToCurrentHost
        )

        if portalBindingStillLive() && shouldApplyImmediateHostedState {
            hostedView.setVisibleInUI(isVisibleInUI)
            hostedView.setActive(isActive)
        } else {
            // Preserve portal entry visibility while a stale host is still receiving SwiftUI updates.
            // The currently bound host remains authoritative for immediate visible/active state.
#if DEBUG
            if desiredStateChanged {
                cmuxDebugLog(
                    "ws.hostState.deferApply surface=\(terminalSurface.id.uuidString.prefix(5)) " +
                    "reason=\(hostOwnsPortalNow ? "staleHostBinding" : "hostOwnershipRejected") " +
                    "hostWindow=\(hostWindowAttached ? 1 : 0) " +
                    "boundToCurrent=\(isBoundToCurrentHost ? 1 : 0) hostedSuperview=\(hostedView.superview != nil ? 1 : 0) " +
                    "visible=\(isVisibleInUI ? 1 : 0) active=\(isActive ? 1 : 0)"
                )
            }
#endif
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.attachGeneration += 1
        coordinator.desiredIsActive = false
        coordinator.desiredIsVisibleInUI = false
        coordinator.desiredShowsUnreadNotificationRing = false
        coordinator.desiredPortalZPriority = 0
        coordinator.lastBoundHostId = nil
        let hostedView = coordinator.hostedView
#if DEBUG
        if let hostedView {
            if let snapshot = AppDelegate.shared?.tabManager?.debugCurrentWorkspaceSwitchSnapshot() {
                let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
                cmuxDebugLog(
                    "ws.swiftui.dismantle id=\(snapshot.id) dt=\(String(format: "%.2fms", dtMs)) " +
                    "surface=\(hostedView.debugSurfaceId?.uuidString.prefix(5) ?? "nil") " +
                    "inWindow=\(hostedView.window != nil ? 1 : 0)"
                )
            } else {
                cmuxDebugLog(
                    "ws.swiftui.dismantle id=none surface=\(hostedView.debugSurfaceId?.uuidString.prefix(5) ?? "nil") " +
                    "inWindow=\(hostedView.window != nil ? 1 : 0)"
                )
            }
        }
#endif

        if let host = nsView as? HostContainerView {
            host.onDidMoveToWindow = nil
            host.onGeometryChanged = nil
            hostedView?.prepareOwnedPortalHostForTransientReattach(
                hostId: ObjectIdentifier(host),
                reason: "dismantle"
            )
        }

        // SwiftUI can transiently dismantle/rebuild NSViewRepresentable instances during split
        // tree updates. Do not drop the portal lease or force visible/active false here; that
        // causes avoidable blackouts when the same hosted view is rebound moments later.
        hostedView?.setFocusHandler(nil)
        hostedView?.setTriggerFlashHandler(nil)
        hostedView?.setDropZoneOverlay(zone: nil)
        coordinator.hostedView = nil

        nsView.subviews.forEach { $0.removeFromSuperview() }
    }
}
