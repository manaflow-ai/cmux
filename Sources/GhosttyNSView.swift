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


enum GhosttyRenderedFrameNotificationDemand {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var count = 0

    static func retain() -> () -> Void {
        lock.lock()
        count += 1
        lock.unlock()

        return {
            lock.lock()
            count = max(0, count - 1)
            lock.unlock()
        }
    }

    static var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return count > 0
    }
}

class GhosttyNSView: NSView, NSUserInterfaceValidations {
    static let focusDebugEnabled: Bool = {
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

    static let dropTypes: Set<NSPasteboard.PasteboardType> = PasteboardFileURLReader.fileURLPasteboardTypes.union([
        .string,
        .URL,
        .png,
        .tiff,
        NSPasteboard.PasteboardType(UTType.jpeg.identifier),
        NSPasteboard.PasteboardType(UTType.gif.identifier),
        NSPasteboard.PasteboardType(UTType.heic.identifier),
        NSPasteboard.PasteboardType(UTType.heif.identifier)
    ])
    static let tabTransferPasteboardType = NSPasteboard.PasteboardType("com.splittabbar.tabtransfer")
    static let sidebarTabReorderPasteboardType = NSPasteboard.PasteboardType("com.cmux.sidebar-tab-reorder")

    weak var terminalSurface: TerminalSurface?
    var scrollbar: GhosttyScrollbar?
    /// Pending scrollbar value written from the action callback thread;
    /// read and cleared on the main thread by `flushPendingScrollbar()`.
    /// Access is guarded by `_scrollbarLock` because the action callback
    /// fires on Ghostty's I/O thread while the flush runs on main.
    var _pendingScrollbar: GhosttyScrollbar?
    var _scrollbarFlushScheduled = false
    let _scrollbarLock = NSLock()
    var _renderedFrameFlushScheduled = false
    let _renderedFrameLock = NSLock()
    var cellSize: CGSize = .zero
    var lastKnownMousePointInView: NSPoint?

    static func retainRenderedFrameNotifications() -> () -> Void {
        GhosttyRenderedFrameNotificationDemand.retain()
    }

    var desiredFocus: Bool = false
    var suppressingReparentFocus: Bool = false
    var tabId: UUID?
    var onFocus: (() -> Void)?
    var onTriggerFlash: (() -> Void)?
    var backgroundColor: NSColor?
    var appliedColorScheme: ghostty_color_scheme_e?
    var lastLoggedSurfaceBackgroundSignature: String?
    var lastLoggedWindowBackgroundSignature: String?
    var keySequence: [ghostty_input_trigger_s] = []
    var keyTables: [String] = []
    var keyboardCopyModeActive = false
    var wordPathHoverActive = false
    var keyboardCopyModeConsumedKeyUps: Set<UInt16> = []
    var imeConsumedKeyUps: Set<UInt16> = []
    var keyboardCopyModeInputState = TerminalKeyboardCopyModeInputState()
    var keyboardCopyModeCursor: TerminalKeyboardCopyModeCursor?
    var keyboardCopyModePendingViewportJumpSync = false
    var keyboardCopyModePendingViewportJumpScrollbarOffset: UInt64?
    var keyboardCopyModePendingViewportJumpGeneration = 0
    var keyboardCopyModePendingViewportJumpFallbackLineDelta: Int?
    var keyboardCopyModePendingViewportJumpAppliedFallbackLineDelta = 0
    /// Tracks whether the user has explicitly entered visual selection mode (v).
    /// Separate from Ghostty's `has_selection` because non-visual copy mode keeps
    /// the cursor in AppKit overlay state until visual selection starts.
    var keyboardCopyModeVisualActive = false
    let keyboardCopyModeCursorOverlayView = GhosttyFlashOverlayView(frame: .zero)
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
    static let keyLatencyProbeEnabled: Bool = {
        if ProcessInfo.processInfo.environment["CMUX_KEY_LATENCY_PROBE"] == "1" {
            return true
        }
        return UserDefaults.standard.bool(forKey: "cmuxKeyLatencyProbe")
    }()
    @MainActor static var debugGhosttySurfaceKeyEventObserver: ((ghostty_input_key_s) -> Void)?
    @MainActor static var debugTextInputEventHandler: ((GhosttyNSView, NSEvent) -> Bool)?
#endif
    var eventMonitor: Any?
    var trackingArea: NSTrackingArea?
    var windowObserver: NSObjectProtocol?
    var lastScrollEventTime: CFTimeInterval = 0
    var visibleInUI: Bool = true
    var pendingSurfaceSize: CGSize?
    var deferredSurfaceSizeRetryQueued = false
    var lastDrawableSize: CGSize = .zero
    var isFindEscapeSuppressionArmed = false
    var hasPendingLeftMouseRelease = false
#if DEBUG
    var lastSizeSkipSignature: String?
#endif

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

    // Convenience accessor for the ghostty surface
    var surface: ghostty_surface_t? {
        terminalSurface?.surface
    }

    // For NSTextInputClient - accumulates text during key events
    var keyTextAccumulator: [String]? = nil
    var markedText = NSMutableAttributedString()
    var markedSelectedRange = NSRange(location: NSNotFound, length: 0)
    var lastPerformKeyEvent: TimeInterval?
    var externalCommittedTextDepth = 0
    var numpadIMECommitDeduplicator = NumpadIMECommitDeduplicator()
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
    var imePointOverrideForTesting: (x: Double, y: Double, width: Double, height: Double)?
    func setIMEPointForTesting(x: Double, y: Double, width: Double, height: Double) { imePointOverrideForTesting = (x, y, width, height) }
    func clearIMEPointForTesting() { imePointOverrideForTesting = nil }
#endif

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


    // MARK: - Key-equivalent fallback (overridden by tests; must live in the class body)
    func performKeyEquivalentAfterMenuMiss(with event: NSEvent) -> Bool {
        performKeyEquivalent(with: event, shouldRetryMainMenu: false)
    }
}

